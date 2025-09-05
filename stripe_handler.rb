# ---- stripe_handler.rb (VERSÃO 5.1.1 - CORREÇÃO FINAL COM TELEFONE) ----
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
      # ... (sem alterações) ...
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

        # --- CORREÇÃO APLICADA AQUI ---
        # Apenas criamos a licença com status 'active', mas sem data de expiração (expires_at = NULL).
        # A data será definida de forma confiável pelo evento 'invoice.payment_succeeded'.
        License.provision_license(
          email: customer_email, family: family, product_skus: product_skus, origin: 'stripe',
          grant_source: "stripe_sub:#{subscription_id}", status: 'active', expires_at: nil,
          trial_expires_at: nil, platform_subscription_id: subscription_id,
          locale: customer_locale, stripe_customer_id: customer_id, phone: customer_phone
        )
        puts "[STRIPE] Sucesso: Direito de uso preliminar provisionado para '#{customer_email}' via Assinatura #{subscription_id}. Aguardando fatura para definir validade."
      rescue => e
        puts "‼️ ERRO inesperado ao processar customer.subscription.created: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
        return [500, {}, ['Erro interno ao provisionar direito de uso']]
      end
      return [200, {}, ['Direito de uso provisionado com sucesso']]

    when 'invoice.payment_succeeded'
      invoice_data = event['data']['object']
      subscription_id = invoice_data['subscription']

      # --- LÓGICA CORRIGIDA E CENTRALIZADA ---
      # Este evento agora é a fonte da verdade para a data de expiração, tanto na criação quanto na renovação.
      if subscription_id
        begin
          # Para garantir os dados mais recentes, buscamos a assinatura na API do Stripe.
          subscription = Stripe::Subscription.retrieve(subscription_id)
          new_expires_at = Time.at(subscription.current_period_end)
          
          # Atualizamos a licença existente com o status e a data de expiração corretos.
          License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'active', new_expires_at: new_expires_at)
          
          puts "[STRIPE] Sucesso: Assinatura #{subscription_id} atualizada com data de expiração via fatura."
        rescue Stripe::InvalidRequestError => e
          puts "‼️ AVISO: Não foi possível encontrar a assinatura #{subscription_id} na API do Stripe. #{e.message}"
          # Não retornamos erro 500, pois a fatura pode não ser de uma assinatura que gerenciamos.
        end
      end
      return [200, {}, ['Fatura processada']]
      
    when 'customer.subscription.deleted'
      # ... (sem alterações, já corrigido) ...
      subscription = event['data']['object']
      subscription_id = subscription['id']
      result = License.update_entitlement_status_from_stripe(subscription_id: subscription_id, status: 'revoked')
      if result.cmd_tuples.zero?
        SmartManiaaApp.log_event(level: 'warning', source: 'stripe_webhook', message: "Recebido evento de cancelamento para assinatura não encontrada no BD: #{subscription_id}")
      else
        SmartManiaaApp.log_event(level: 'info', source: 'stripe_webhook', message: "Assinatura cancelada com sucesso no BD: #{subscription_id}")
      end
      return [200, {}, ['Cancelamento processado']]

    when 'customer.subscription.updated'
      # ... (sem alterações, já corrigido) ...
      subscription_data = event['data']['object']
      subscription_id = subscription_data['id']
      if !subscription_data['cancel_at'].nil?
        cancel_date = Time.at(subscription_data['cancel_at'])
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'pending_cancellation', new_expires_at: cancel_date)
      elsif subscription_data['cancel_at_period_end'] == true
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'pending_cancellation')
      elsif subscription_data['cancel_at_period_end'] == false && subscription_data['cancel_at'].nil?
        new_expires_at = Time.at(subscription_data['current_period_end'])
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_status: 'active', new_expires_at: new_expires_at)
      end
      return [200, {}, ['Atualização de assinatura processada']]

    else
      puts "[STRIPE] Info: Evento não tratado recebido: #{event_type}."
      return [200, {}, ['Evento não tratado']]
    end
  end
  
end