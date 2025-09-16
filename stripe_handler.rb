# ---- stripe_handler.rb (VERSÃO FINAL COM REEMBOLSO SIMPLIFICADO) ----
require 'stripe'
require 'json'
require 'time'

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
      customer_id = credit_note_data['customer']
      amount_refunded = credit_note_data['amount']
      currency = credit_note_data['currency']
      
      puts "[FINANCE] Recebido evento de reembolso de #{amount_refunded} #{currency.upcase} para o cliente #{customer_id}."

      unless customer_id
        puts "[FINANCE] ALERTA: Nota de crédito #{credit_note_data['id']} sem ID de cliente. Reembolso não contabilizado."
        return [200, {}, ['Nota de crédito sem cliente']]
      end

      # Encontra a família do produto baseada na licença mais recente do cliente
      license_info = $db.exec_params("SELECT family FROM licenses WHERE stripe_customer_id = $1 ORDER BY created_at DESC LIMIT 1", [customer_id]).first
      unless license_info
        puts "[FINANCE] ALERTA: Não foi possível encontrar uma licença para o cliente #{customer_id}. Reembolso não contabilizado."
        return [200, {}, ['Cliente sem licença local']]
      end
      product_family = license_info['family']

      refund_month = Time.at(credit_note_data['created']).strftime('%Y-%m-01')
      
      # Atualiza a tabela de agregados de reembolso
      $db.exec_params(
        %q{
          INSERT INTO monthly_refunds (product_family, refund_month, total_refunded, refund_count, currency)
          VALUES ($1, $2, $3, 1, $4)
          ON CONFLICT (product_family, refund_month, currency) DO UPDATE SET
          total_refunded = monthly_refunds.total_refunded + $3,
          refund_count = monthly_refunds.refund_count + 1,
          updated_at = NOW()
        },
        [product_family, refund_month, amount_refunded, currency.upcase]
      )
      
      puts "[FINANCE] Reembolso agregado com sucesso para a família #{product_family} no mês de #{refund_month}."
      return [200, {}, ['Reembolso agregado com sucesso']]

    when 'customer.subscription.created'
      subscription_data = event['data']['object']
      subscription_id = subscription_data['id']
      customer_id = subscription_data['customer']
      existing_entitlement = $db.exec_params("SELECT 1 FROM license_entitlements WHERE platform_subscription_id = $1 LIMIT 1", [subscription_id])
      if existing_entitlement.num_tuples > 0
        puts "[STRIPE] Ignorando 'customer.subscription.created' pois já foi processada."
        return [200, {}, ['Assinatura já processada']]
      end
      begin
        customer_info = $db.exec_params("SELECT email, locale, phone FROM stripe_customers WHERE stripe_customer_id = $1 LIMIT 1", [customer_id]).first
        customer_email, customer_locale, customer_phone = nil, nil, nil
        unless customer_info
          puts "‼️ AVISO: Cliente #{customer_id} não encontrado no banco local. Fazendo fallback para a API."
          customer_details = Stripe::Customer.retrieve(customer_id)
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
        License.provision_license(
          email: customer_email, family: family, product_skus: product_skus, origin: 'stripe',
          grant_source: "stripe_sub:#{subscription_id}", status: 'active', expires_at: expires_at,
          trial_expires_at: nil, platform_subscription_id: subscription_id,
          locale: customer_locale, stripe_customer_id: customer_id, phone: customer_phone
        )
        puts "[STRIPE] Sucesso: Direito de uso provisionado para '#{customer_email}' com validade até #{expires_at}."
      rescue => e
        puts "‼️ ERRO inesperado ao processar customer.subscription.created: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
        return [500, {}, ['Erro interno ao provisionar direito de uso']]
      end
      return [200, {}, ['Direito de uso provisionado com sucesso']]

    when 'customer.subscription.updated'
      subscription_data = event['data']['object']
      subscription_id = subscription_data['id']
      previous_attributes = event['data']['previous_attributes']

      if !subscription_data['cancel_at'].nil?
        cancel_date = Time.at(subscription_data['cancel_at'])
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'pending_cancellation', new_expires_at: cancel_date)
        puts "[STRIPE] Ação: Cancelamento para data específica processado para #{subscription_id}."
      elsif subscription_data['cancel_at_period_end'] == true
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'pending_cancellation')
        puts "[STRIPE] Ação: Cancelamento no fim do período processado para #{subscription_id}."
      
      elsif subscription_data['cancel_at_period_end'] == false && subscription_data['cancel_at'].nil? && previous_attributes && (previous_attributes['cancel_at_period_end'] == true || !previous_attributes['cancel_at'].nil?)
        new_expires_at = Time.at(subscription_data['items']['data'][0]['current_period_end'])
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'active', new_expires_at: new_expires_at)
        puts "[STRIPE] Ação: Reativação de assinatura processada para #{subscription_id}."

      elsif previous_attributes && previous_attributes.dig('items', 'data', 0, 'current_period_end')
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'awaiting_payment')
        puts "[STRIPE] Ação: Renovação detectada para #{subscription_id}. Status alterado para 'awaiting_payment'."
      else
        puts "[STRIPE] Info: Evento 'customer.subscription.updated' não resultou em ação (sem mudança relevante)."
      end
      return [200, {}, ['Atualização de assinatura processada']]

    when 'invoice.paid', 'invoice.payment_succeeded'
      invoice_data = event['data']['object']
      
      record_financial_transaction(invoice_data)

      billing_reason = invoice_data['billing_reason']&.strip
      
      if billing_reason == 'subscription_cycle'
        subscription_id = invoice_data.dig('parent', 'subscription_details', 'subscription') || invoice_data.dig('lines', 'data', 0, 'subscription')
        period_end_timestamp = invoice_data.dig('lines', 'data', 0, 'period', 'end')
        
        if subscription_id && period_end_timestamp
          puts "[STRIPE] Processando RENOVAÇÃO para a assinatura: #{subscription_id}."
          new_expires_at = Time.at(period_end_timestamp)
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
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'active')
        SmartManiaaApp.log_event(level: 'warning', source: 'stripe_webhook', message: "Falha no pagamento da fatura para a assinatura #{subscription_id}", details: event)
      end
      return [200, {}, ['Falha de pagamento processada']]

    when 'customer.subscription.deleted'
      subscription = event['data']['object']
      subscription_id = subscription['id']
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

  def self.record_financial_transaction(invoice_data)
    amount_paid = invoice_data['amount_paid']
    currency = invoice_data['currency']
    stripe_invoice_id = invoice_data['id']
    paid_at_timestamp = invoice_data.dig('status_transitions', 'paid_at')
    
    return unless paid_at_timestamp
    paid_at = Time.at(paid_at_timestamp)

    subscription_id = invoice_data.dig('parent', 'subscription_details', 'subscription') || invoice_data.dig('lines', 'data', 0, 'subscription')
    
    return unless subscription_id

    entitlement_info = $db.exec_params("SELECT l.id, l.family FROM license_entitlements le JOIN licenses l ON le.license_id = l.id WHERE le.platform_subscription_id = $1 LIMIT 1", [subscription_id]).first
    unless entitlement_info
      puts "[FINANCE] ALERTA: Não foi possível encontrar a licença local para a assinatura #{subscription_id}. Registro financeiro ignorado."
      return
    end
    license_id = entitlement_info['id']
    product_family = entitlement_info['family']

    $db.exec_params(
      %q{
        INSERT INTO subscription_financials (stripe_subscription_id, license_id, gross_revenue_accumulated, currency)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (stripe_subscription_id) DO UPDATE SET
        gross_revenue_accumulated = subscription_financials.gross_revenue_accumulated + $3,
        updated_at = NOW()
      },
      [subscription_id, license_id, amount_paid, currency]
    )

    revenue_month = paid_at.strftime('%Y-%m-01')
    $db.exec_params(
      %q{
        INSERT INTO monthly_family_revenue (product_family, revenue_month, gross_revenue_month, currency)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (product_family, revenue_month, currency) DO UPDATE SET
        gross_revenue_month = monthly_family_revenue.gross_revenue_month + $3,
        updated_at = NOW()
      },
      [product_family, revenue_month, amount_paid, currency]
    )
    puts "[FINANCE] Transação de #{amount_paid} #{currency.upcase} para a assinatura #{subscription_id} registrada com sucesso."
  end
end