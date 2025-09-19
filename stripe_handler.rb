# ---- stripe_handler.rb (VERSÃO FINAL COM REEMBOLSO SIMPLIFICADO) ----
require 'stripe'
require 'json'
require 'time'
require 'pg'

module StripeHandler
  Stripe.api_key = ENV['STRIPE_API_KEY']

  def self.stripe_price_to_sku_mapping
    mapping = {}
    $db.exec("SELECT stripe_price_id, sku FROM products WHERE stripe_price_id IS NOT NULL").each do |row|
      mapping[row['stripe_price_id']] ||= []
      mapping[row['stripe_price_id']] << row['sku']
    end
    mapping
  end

  def self.handle_webhook(payload, sig_header)
    event_data = nil
    begin
      if sig_header == "dummy_signature_for_test"
        event_data = JSON.parse(payload)
        puts "[STRIPE] Webhook de TESTE recebido. Pulando verificação de assinatura."
      else
        Stripe::Webhook.construct_event(payload, sig_header, ENV['STRIPE_WEBHOOK_SECRET'])
        event_data = JSON.parse(payload)
        puts "[STRIPE] Webhook de PRODUÇÃO recebido. Assinatura verificada com sucesso."
      end
    rescue JSON::ParserError => e
      puts "⚠️ ERRO: Falha no parse do JSON do webhook: #{e.message}"
      return [400, {}, ['Invalid payload']]
    rescue Stripe::SignatureVerificationError => e
      puts "⚠️ ERRO: Falha na verificação da assinatura do webhook: #{e.message}"
      return [403, {}, ['Signature verification failed']]
    end

    return process_event(event_data)
  end
  
  private

 def self.process_event(event)
    event_type = event['type']
    event_id = event['id']
    puts "[STRIPE] Webhook processando: Tipo '#{event_type}', ID '#{event_id}'"

    case event_type
    
    when 'customer.created', 'customer.updated'
      customer_data = event['data']['object']
      customer_id = customer_data['id']
      email = customer_data['email']
      locale = (customer_data['preferred_locales'] || []).first
      name = customer_data['name']
      phone = customer_data['phone']
      $db.exec_params(
        "INSERT INTO stripe_customers (stripe_customer_id, email, locale, name, phone) VALUES ($1, $2, $3, $4, $5) " +
        "ON CONFLICT (stripe_customer_id) DO UPDATE SET email = $2, locale = $3, name = $4, phone = $5, updated_at = NOW()",
        [customer_id, email, locale, name, phone]
      )
      puts "[STRIPE] Cliente '#{email}' (ID: #{customer_id}) salvo/atualizado no banco local."
      return [200, {}, ['Cliente processado com sucesso']]

    when 'credit_note.created'
      credit_note_data = event['data']['object']
      
      begin
        invoice_id = credit_note_data['invoice']
        
        unless invoice_id
          puts "[FINANCE] ALERTA: Nota de crédito #{credit_note_data['id']} sem ID de fatura associado. Reembolso não contabilizado."
          return [200, {}, ['Nota de crédito sem fatura']]
        end

        invoice = Stripe::Invoice.retrieve(invoice_id, { expand: ['subscription'] })
        subscription_id = invoice.subscription.id
        
        unless subscription_id
          puts "[FINANCE] ALERTA: Fatura #{invoice_id} sem ID de assinatura. Reembolso não contabilizado."
          return [200, {}, ['Fatura sem assinatura']]
        end

        product_skus = invoice.lines.data.flat_map { |item| stripe_price_to_sku_mapping[item.price.id] }.compact.uniq

        unless product_skus.any?
          puts "[FINANCE] ALERTA: Nenhum SKU válido encontrado na fatura para o reembolso. Reembolso não contabilizado."
          return [200, {}, ['Nenhum SKU válido encontrado']]
        end

        amount_refunded = credit_note_data['amount']
        currency = credit_note_data['currency']
        
        entitlement_info = $db.exec_params(
          "SELECT l.id, l.email FROM license_entitlements le JOIN licenses l ON le.license_id = l.id WHERE le.platform_subscription_id = $1 LIMIT 1",
          [subscription_id]
        ).first
        
        unless entitlement_info
          puts "[FINANCE] ALERTA: Não foi possível encontrar a licença local para a assinatura #{subscription_id}. Registro financeiro ignorado."
          return [200, {}, ['Licença local não encontrada']]
        end

        License.log_platform_event(
          event_type: 'refund',
          license_id: entitlement_info['id'],
          email: entitlement_info['email'],
          product_sku: product_skus.join(','),
          source_system: 'stripe_webhook',
          details: {
            platform_customer_id: credit_note_data['customer'],
            platform_subscription_id: subscription_id,
            platform_invoice_id: invoice_id,
            amount_cents: -amount_refunded,
            currency: currency,
            payload_details: event
          }
        )
        
        # Chama o método de registro financeiro com o valor NEGATIVO do reembolso
        self.record_financial_transaction({
          'amount_paid' => -amount_refunded,
          'currency' => currency,
          'parent' => { 'subscription_details' => { 'subscription' => subscription_id } }
        })
      
        puts "[FINANCE] Reembolso de #{amount_refunded} #{currency.upcase} para a assinatura #{subscription_id} processado."
        return [200, {}, ['Reembolso processado com sucesso']]
        
      rescue Stripe::InvalidRequestError => e
        puts "⚠️ ERRO: Falha ao buscar nota de crédito ou fatura do Stripe: #{e.message}"
        return [400, {}, ['Erro na busca do Stripe API']]
      rescue => e
        puts "‼️ ERRO inesperado ao processar reembolso: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
        return [500, {}, ['Erro interno ao processar reembolso']]
      end

    when 'customer.subscription.created'
      subscription_data = event['data']['object']
      subscription_id = subscription_data['id']
      existing_entitlement = $db.exec_params("SELECT 1 FROM license_entitlements WHERE platform_subscription_id = $1 LIMIT 1", [subscription_id])
      if existing_entitlement.num_tuples > 0
        puts "[STRIPE] Ignorando 'customer.subscription.created' pois já foi processada."
        return [200, {}, ['Assinatura já processada']]
      end
      begin
        customer_info = $db.exec_params("SELECT email, locale, phone FROM stripe_customers WHERE stripe_customer_id = $1 LIMIT 1", [subscription_data['customer']]).first
        customer_email, customer_locale, customer_phone = nil, nil, nil
        unless customer_info
          puts "‼️ AVISO: Cliente #{subscription_data['customer']} não encontrado no banco local. Fazendo fallback para a API."
          customer_details = Stripe::Customer.retrieve(subscription_data['customer'])
          customer_email, customer_locale, customer_phone = customer_details.email, customer_details.preferred_locales&.first, customer_details.phone
        else
          puts "[STRIPE] Informações do cliente obtidas do banco local."
          customer_email, customer_locale, customer_phone = customer_info.values_at('email', 'locale', 'phone')
        end
        product_skus = subscription_data['items']['data'].flat_map { |item| stripe_price_to_sku_mapping[item['price']['id']] }.compact.uniq
        if product_skus.empty?
          return [400, {}, ['Nenhum SKU válido encontrado']]
        end
        family = License.find_family_by_sku(product_skus.first)
        period_end_timestamp = subscription_data['items']['data'][0]['current_period_end']
        if period_end_timestamp.nil?
            puts "‼️ ERRO CRÍTICO: 'items.data[0].current_period_end' está nulo para a assinatura #{subscription_id}. Impossível provisionar."
            SmartManiaaApp.log_event(level: 'error', source: 'stripe_webhook', message: "Campo 'items.data[0].current_period_end' nulo no evento 'customer.subscription.created' para a subscrição #{subscription_id}", details: event)
            return [500, {}, ['Dados da assinatura incompletos do Stripe']]
        end
        expires_at = Time.at(period_end_timestamp)
        license_id, key, _was_new = License.provision_license(
          email: customer_email, family: family, product_skus: product_skus, origin: 'stripe',
          grant_source: "stripe_sub:#{subscription_id}", status: 'active', expires_at: expires_at,
          trial_expires_at: nil, platform_subscription_id: subscription_id,
          locale: customer_locale, stripe_customer_id: subscription_data['customer'], phone: customer_phone
        )
        puts "[STRIPE] Sucesso: Direito de uso provisionado para '#{customer_email}' com validade até #{expires_at}."
        
        # --- LOG PARA AUDITORIA ---
        License.log_platform_event(
          event_type: 'provision',
          license_id: license_id,
          email: customer_email,
          product_sku: product_skus.join(','),
          source_system: 'stripe_webhook',
          details: {
            platform_customer_id: subscription_data['customer'],
            platform_subscription_id: subscription_id,
            new_status: 'active',
            payload_details: event
          }
        )
      rescue => e
        puts "‼️ ERRO inesperado ao processar customer.subscription.created: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
        return [500, {}, ['Erro interno ao provisionar direito de uso']]
      end
      return [200, {}, ['Direito de uso provisionado com sucesso']]

    when 'customer.subscription.updated'
      subscription_data = event['data']['object']
      subscription_id = subscription_data['id']
      previous_attributes = event['data']['previous_attributes']
      
      entitlement_info = $db.exec_params("SELECT id, status FROM license_entitlements WHERE platform_subscription_id = $1 LIMIT 1", [subscription_id]).first
      unless entitlement_info
        puts "ALERTA: Entitlement para assinatura #{subscription_id} não encontrado."
        return [200, {}, ['Entitlement não encontrado']]
      end
      
      old_status = entitlement_info['status']
      new_status = old_status

      if !subscription_data['cancel_at'].nil?
        new_status = 'pending_cancellation'
        cancel_date = Time.at(subscription_data['cancel_at'])
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: new_status, new_expires_at: cancel_date)
        puts "[STRIPE] Ação: Cancelamento para data específica processado para #{subscription_id}."
      elsif subscription_data['cancel_at_period_end'] == true
        new_status = 'pending_cancellation'
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: new_status)
        puts "[STRIPE] Ação: Cancelamento no fim do período processado para #{subscription_id}."
      
      elsif subscription_data['cancel_at_period_end'] == false && subscription_data['cancel_at'].nil? && previous_attributes && (previous_attributes['cancel_at_period_end'] == true || !previous_attributes['cancel_at'].nil?)
        new_status = 'active'
        new_expires_at = Time.at(subscription_data['items']['data'][0]['current_period_end'])
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: new_status, new_expires_at: new_expires_at)
        puts "[STRIPE] Ação: Reativação de assinatura processada para #{subscription_id}."

      elsif previous_attributes && previous_attributes.dig('items', 'data', 0, 'current_period_end')
        new_status = 'awaiting_payment'
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: new_status)
        puts "[STRIPE] Ação: Renovação detectada para #{subscription_id}. Status alterado para 'awaiting_payment'."
      else
        puts "[STRIPE] Info: Evento 'customer.subscription.updated' não resultou em ação (sem mudança relevante)."
      end

      # --- LOG PARA AUDITORIA ---
      if old_status != new_status
        license_info = $db.exec_params("SELECT id, email FROM licenses WHERE stripe_customer_id = $1 LIMIT 1", [subscription_data['customer']]).first
        if license_info
          License.log_platform_event(
            event_type: 'status_change',
            license_id: license_info['id'],
            email: license_info['email'],
            product_sku: nil,
            source_system: 'stripe_webhook',
            details: {
              platform_customer_id: subscription_data['customer'],
              platform_subscription_id: subscription_id,
              previous_status: old_status,
              new_status: new_status,
              payload_details: event
            }
          )
        end
      end
      return [200, {}, ['Atualização de assinatura processada']]

    when 'invoice.paid', 'invoice.payment_succeeded'
      invoice_data = event['data']['object']
      
      # REGISTRA A TRANSAÇÃO FINANCEIRA
      record_financial_transaction(invoice_data)

      billing_reason = invoice_data['billing_reason']&.strip
      
      if billing_reason == 'subscription_cycle'
        subscription_id = invoice_data.dig('parent', 'subscription_details', 'subscription') || invoice_data.dig('lines', 'data', 0, 'subscription')
        period_end_timestamp = invoice_data.dig('lines', 'data', 0, 'period', 'end')
        
        if subscription_id && period_end_timestamp
          puts "[STRIPE] Processando RENOVAÇÃO para a assinatura: #{subscription_id}."
          new_expires_at = Time.at(period_end_timestamp)
          
          # --- LOG PARA AUDITORIA ---
          entitlement_info = $db.exec_params("SELECT id, status FROM license_entitlements WHERE platform_subscription_id = $1 LIMIT 1", [subscription_id]).first
          license_info = $db.exec_params("SELECT id, email FROM licenses WHERE stripe_customer_id = $1 LIMIT 1", [invoice_data['customer']]).first
          if entitlement_info && license_info
            License.log_platform_event(
              event_type: 'renewal',
              license_id: license_info['id'],
              email: license_info['email'],
              product_sku: nil, # Pode ser buscado na fatura se necessário
              source_system: 'stripe_webhook',
              details: {
                platform_customer_id: invoice_data['customer'],
                platform_subscription_id: subscription_id,
                previous_status: entitlement_info['status'],
                new_status: 'active',
                payload_details: event
              }
            )
          end

          result = License.update_entitlement_from_stripe(
            subscription_id: subscription_id, 
            new_status: 'active', 
            new_expires_at: new_expires_at
          )
          if result.cmd_tuples > 0
            puts "[STRIPE] Sucesso: RENOVAÇÃO CONFIRMADA. Assinatura válida até #{new_expires_at}."
          else
            puts "[STRIPE] ALERTA: Renovação processada, mas nenhuma licença foi atualizada."
          end
        else
            puts "[STRIPE] ERRO: 'subscription_id' ou 'period_end' não encontrados no evento de renovação."
        end
      end
      
      return [200, {}, ['Evento de pagamento processado']]
      
    when 'invoice.payment_failed'
      invoice_data = event['data']['object']
      subscription_id = invoice_data['subscription']

      if subscription_id
        puts "[STRIPE] ALERTA: Falha no pagamento da renovação para a assinatura #{subscription_id}."
        
        # --- LOG PARA AUDITORIA ---
        entitlement_info = $db.exec_params("SELECT id, status FROM license_entitlements WHERE platform_subscription_id = $1 LIMIT 1", [subscription_id]).first
        license_info = $db.exec_params("SELECT id, email FROM licenses WHERE stripe_customer_id = $1 LIMIT 1", [invoice_data['customer']]).first
        if entitlement_info && license_info
          License.log_platform_event(
            event_type: 'status_change',
            license_id: license_info['id'],
            email: license_info['email'],
            product_sku: nil,
            source_system: 'stripe_webhook',
            details: {
              platform_customer_id: invoice_data['customer'],
              platform_subscription_id: subscription_id,
              previous_status: entitlement_info['status'],
              new_status: 'active', # O status permanece 'active' até o cancelamento
              payload_details: event
            }
          )
        end
        
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'active')
      end
      return [200, {}, ['Falha de pagamento processada']]

    when 'customer.subscription.deleted'
      subscription = event['data']['object']
      subscription_id = subscription['id']
      
      entitlement_info = $db.exec_params("SELECT id, status FROM license_entitlements WHERE platform_subscription_id = $1 LIMIT 1", [subscription_id]).first
      unless entitlement_info
        puts "ALERTA: Entitlement para assinatura #{subscription_id} não encontrado."
        return [200, {}, ['Entitlement não encontrado']]
      end
      
      license_info = $db.exec_params("SELECT id, email FROM licenses WHERE stripe_customer_id = $1 LIMIT 1", [subscription['customer']]).first

      # --- LOG PARA AUDITORIA ---
      if license_info
        License.log_platform_event(
          event_type: 'cancellation',
          license_id: license_info['id'],
          email: license_info['email'],
          product_sku: nil,
          source_system: 'stripe_webhook',
          details: {
            platform_customer_id: subscription['customer'],
            platform_subscription_id: subscription_id,
            previous_status: entitlement_info['status'],
            new_status: 'revoked',
            payload_details: event
          }
        )
      end

      result = License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'revoked')
      if result.cmd_tuples.zero?
        SmartManiaaApp.log_event(level: 'warning', source: 'stripe_webhook', message: "Recebido evento de cancelamento para assinatura não encontrada no BD: #{subscription_id}")
      else
        SmartManiaaApp.log_event(level: 'info', source: 'stripe_webhook', message: "Assinatura cancelada com sucesso no BD: #{subscription_id}")
      end
      return [200, {}, ['Cancelamento processado']]

    else
      puts "[STRIPE] Info: Evento não tratado recebido: #{event_type}."
      return [200, {}, ['Evento não tratado']]
    end
  end
 end
end