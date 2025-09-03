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

    # Adicionando um log de debug para garantir a correspondência
    puts "[STRIPE] DEBUG: Verificando tipo de evento '#{event_type}' (Classe: #{event_type.class})"

    case event_type
    
    when 'customer.created', 'customer.updated'
      customer_data = event['data']['object']
      customer_id = customer_data['id']
      email = customer_data['email']
      locale = (customer_data['preferred_locales'] || []).first
      name = customer_data['name']
      phone = customer_data['phone'] # <-- CAPTURA O TELEFONE

      # ADICIONA O TELEFONE NA QUERY DO BANCO DE DADOS
      $db.exec_params(
        "INSERT INTO stripe_customers (stripe_customer_id, email, locale, name, phone) VALUES ($1, $2, $3, $4, $5) " +
        "ON CONFLICT (stripe_customer_id) DO UPDATE SET email = $2, locale = $3, name = $4, phone = $5, updated_at = NOW()",
        [customer_id, email, locale, name, phone]
      )
      puts "[STRIPE] Cliente '#{email}' (ID: #{customer_id}) salvo/atualizado no banco local."
      return [200, {}, ['Cliente processado com sucesso']]

    # ---- BLOCO FINAL E CORRIGIDO (customer.subscription.created) ----

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
        # Lógica de buscar cliente e telefone (está correta)
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

        # Lógica de SKU e Família (está correta)
        product_skus = subscription_data['items']['data'].flat_map { |item| stripe_price_to_sku_mapping[item['price']['id']] }.compact.uniq
        if product_skus.empty?
          return [400, {}, ['Nenhum SKU válido encontrado']]
        end
        family = License.find_family_by_sku(product_skus.first)

        # --- CORREÇÃO FINAL APLICADA AQUI ---
        # Restaurando a lógica de data da sua versão 5.1 funcional.
        status = 'active'
        expires_at = if subscription_data['status'] == 'trialing'
                       Time.at(subscription_data['trial_end'])
                     else
                       Time.at(subscription_data['items']['data'][0]['current_period_end'])
                     end
        
        # O resto do código para criar a licença (está correto)
        License.provision_license(
          email: customer_email, family: family, product_skus: product_skus, origin: 'stripe',
          grant_source: "stripe_sub:#{subscription_id}", status: status, expires_at: expires_at,
          trial_expires_at: nil,
          platform_subscription_id: subscription_id,
          locale: customer_locale,
          stripe_customer_id: customer_id,
          phone: customer_phone
        )
        puts "[STRIPE] Sucesso: Direito de uso provisionado para '#{customer_email}' via Assinatura #{subscription_id}."
      rescue => e
        puts "‼️ ERRO inesperado ao processar customer.subscription.created: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
        return [500, {}, ['Erro interno ao provisionar direito de uso']]
      end
      return [200, {}, ['Direito de uso provisionado com sucesso']]
      subscription_data = event['data']['object']
      subscription_id = subscription_data['id']
      customer_id = subscription_data['customer']

      existing_entitlement = $db.exec_params("SELECT 1 FROM license_entitlements WHERE platform_subscription_id = $1 LIMIT 1", [subscription_id])
      if existing_entitlement.num_tuples > 0
        puts "[STRIPE] Ignorando 'customer.subscription.created' pois já foi processada."
        return [200, {}, ['Assinatura já processada']]
      end
      
      begin
        # BUSCA O TELEFONE JUNTO COM O RESTO
        customer_info = $db.exec_params("SELECT email, locale, phone FROM stripe_customers WHERE stripe_customer_id = $1 LIMIT 1", [customer_id]).first
        customer_email, customer_locale, customer_phone = nil, nil, nil

        unless customer_info
          puts "‼️ AVISO: Cliente #{customer_id} não encontrado no banco local. Fazendo fallback para a API."
          customer_details = Stripe::Customer.retrieve(customer_id)
          customer_email = customer_details.email
          customer_locale = customer_details.preferred_locales&.first
          customer_phone = customer_details.phone # <-- PEGA O TELEFONE DO FALLBACK
        else
          puts "[STRIPE] Informações do cliente obtidas do banco local."
          customer_email = customer_info['email']
          customer_locale = customer_info['locale']
          customer_phone = customer_info['phone'] # <-- PEGA O TELEFONE DO BANCO
        end

        product_skus = subscription_data['items']['data'].flat_map { |item| stripe_price_to_sku_mapping[item['price']['id']] }.compact.uniq
        if product_skus.empty?
          puts "[STRIPE] ERRO: Nenhum SKU válido encontrado para a assinatura #{subscription_id}."
          return [400, {}, ['Nenhum SKU válido encontrado']]
        end
        family = License.find_family_by_sku(product_skus.first)

        # Lógica de expiração da Versão 5.1, que sabemos ser funcional
        status = 'active'
        expires_at = if subscription_data['status'] == 'trialing'
                       Time.at(subscription_data['trial_end'])
                     else
                       Time.at(subscription_data['current_period_end'])
                     end
        
        License.provision_license(
          email: customer_email, family: family, product_skus: product_skus, origin: 'stripe',
          grant_source: "stripe_sub:#{subscription_id}", status: status, expires_at: expires_at,
          trial_expires_at: nil,
          platform_subscription_id: subscription_id,
          locale: customer_locale,
          stripe_customer_id: customer_id,
          phone: customer_phone # <-- PASSA O TELEFONE PARA A FUNÇÃO
        )
        puts "[STRIPE] Sucesso: Direito de uso provisionado para '#{customer_email}' via Assinatura #{subscription_id}."
      rescue => e
        puts "‼️ ERRO inesperado ao processar customer.subscription.created: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
        return [500, {}, ['Erro interno ao provisionar direito de uso']]
      end
      return [200, {}, ['Direito de uso provisionado com sucesso']]

    when 'invoice.payment_succeeded'
      invoice_data = event['data']['object']
      subscription_id = invoice_data['subscription']
      if subscription_id && invoice_data['amount_paid'] > 0
        subscription = Stripe::Subscription.retrieve(subscription_id)
        new_expires_at = Time.at(subscription.current_period_end)
        License.update_entitlement_from_stripe(subscription_id: subscription_id, new_expires_at: new_expires_at, new_status: 'active')
        puts "[STRIPE] Sucesso: Renovação processada para Assinatura #{subscription_id}."
      else
        puts "[STRIPE] Info: Fatura de valor zero ('invoice.payment_succeeded') ignorada (início de trial)."
      end
      return [200, {}, ['Renovação processada']]
      
    when 'customer.subscription.deleted'
    # Em stripe_handler.rb
    when 'customer.subscription.updated'
      subscription_data = event['data']['object']
      subscription_id = subscription_data['id']
      
      # Verificamos se o cliente agendou o cancelamento
      if subscription_data['cancel_at_period_end'] == true
        puts "[STRIPE] Ação: Cancelamento agendado detectado para a assinatura #{subscription_id}."
        License.update_entitlement_status_from_stripe(subscription_id: subscription_id, status: 'pending_cancellation')
      
      # Verificamos se o cliente reativou uma assinatura que ia ser cancelada
      elsif subscription_data['cancel_at_period_end'] == false
        puts "[STRIPE] Ação: Reativação de assinatura detectada para #{subscription_id}."
        # Aqui, atualizamos de 'pending_cancellation' de volta para 'active'
        $db.exec_params(
          "UPDATE license_entitlements SET status = 'active' WHERE platform_subscription_id = $1 AND status = 'pending_cancellation'",
          [subscription_id]
        )
      else
        puts "[STRIPE] Info: Assinatura #{subscription_id} foi atualizada (sem alteração no status de cancelamento)."
      end
      return [200, {}, ['Atualização de assinatura processada']]
      subscription_data = event['data']['object']
      
      # Verificamos se o motivo da atualização foi um agendamento de cancelamento
      if subscription_data['cancel_at_period_end'] == true
        puts "[STRIPE] Ação: Cancelamento agendado detectado para a assinatura #{subscription_data['id']}."
        License.update_entitlement_status_from_stripe(
          subscription_id: subscription_data['id'], 
          status: 'pending_cancellation'
        )
      else
        puts "[STRIPE] Info: Assinatura #{subscription_data['id']} foi atualizada (sem agendamento de cancelamento)."
      end
      return [200, {}, ['Atualização de assinatura processada']]
      subscription = event['data']['object']
      License.update_entitlement_status_from_stripe(subscription_id: subscription['id'], status: 'revoked')
      puts "[STRIPE] Ação: Assinatura #{subscription['id']} cancelada."
      return [200, {}, ['Cancelamento processado']]

    else
      puts "[STRIPE] Info: Evento não tratado recebido: #{event_type}."
      return [200, {}, ['Evento não tratado']]
    end
  end
end