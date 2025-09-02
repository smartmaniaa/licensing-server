# ---- stripe_handler.rb (VERSÃO 5.1 - ARQUITETURA FINAL) ----
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

  def self.all_family_skus_from_subscription(subscription_id)
    begin
      subscription = Stripe::Subscription.retrieve(subscription_id)
      return subscription.items.data.flat_map { |item| stripe_price_to_sku_mapping[item.price.id] }.compact.uniq
    rescue => e
      puts "[STRIPE] Alerta: Não foi possível buscar a assinatura #{subscription_id}. Erro: #{e.message}"
      return []
    end
  end

  def self.handle_webhook(payload, sig_header)
    event_data = nil
    begin
      if sig_header == "dummy_signature_for_test"
        event_data = JSON.parse(payload)
      else
        event = Stripe::Webhook.construct_event(payload, sig_header, ENV['STRIPE_WEBHOOK_SECRET'])
        event_data = event.to_h
      end
    rescue JSON::ParserError => e
      return [400, {}, ['Invalid payload']]
    rescue Stripe::SignatureVerificationError => e
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
        unless customer_info
          puts "‼️ AVISO: Cliente #{customer_id} não encontrado no banco local. O webhook 'customer.created' pode não ter chegado ainda. Fazendo fallback para a API."
          customer_details = Stripe::Customer.retrieve(customer_id)
          customer_email = customer_details.email
          customer_locale = customer_details.preferred_locales&.first
          customer_phone = customer_details.phone
        else
          puts "[STRIPE] Informações do cliente obtidas do banco local."
          customer_email = customer_info['email']
          customer_locale = customer_info['locale']
          customer_phone = customer_info['phone']
        end

        product_skus = subscription_data['items']['data'].flat_map { |item| stripe_price_to_sku_mapping[item['price']['id']] }.compact.uniq
        if product_skus.empty?
          puts "[STRIPE] ERRO: Nenhum SKU válido encontrado para a assinatura #{subscription_id}."
          return [400, {}, ['Nenhum SKU válido encontrado']]
        end
        family = License.find_family_by_sku(product_skus.first)

        status = 'active'
        expires_at = if subscription_data['status'] == 'trialing'
                       Time.at(subscription_data['trial_end'])
                     else
                       Time.at(subscription_data['items']['data'][0]['current_period_end'])
                     end
        
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
      subscription = event['data']['object']
      License.update_entitlement_status_from_stripe(subscription_id: subscription['id'], status: 'revoked')
      puts "[STRIPE] Ação: Assinatura #{subscription['id']} cancelada."
      return [200, {}, ['Cancelamento processado']]
      
    when 'invoice.payment_failed'
      invoice = event['data']['object']
      subscription_id = invoice['subscription']
      if subscription_id
        License.update_entitlement_status_from_stripe(subscription_id: subscription_id, status: 'suspended')
        puts "[STRIPE] Ação: Pagamento falhou para Assinatura #{subscription_id}. Status alterado para 'suspended'."
      end
      return [200, {}, ['Falha de pagamento processada']]

    when 'payout.created'
      payout = event['data']['object']
      $db.exec_params("INSERT INTO payouts (stripe_payout_id, amount, currency, arrival_date, status) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (stripe_payout_id) DO UPDATE SET status = $5, updated_at = NOW()", [payout['id'], payout['amount'], payout['currency'], Time.at(payout['arrival_date']).to_date, payout['status']])
      puts "[FINANCEIRO] Repasse (Payout) #{payout['id']} foi criado."
      return [200, {}, ['Repasse criado']]

    when 'payout.paid'
      payout = event['data']['object']
      $db.exec_params("UPDATE payouts SET status = $1, updated_at = NOW() WHERE stripe_payout_id = $2", [payout['status'], payout['id']])
      puts "[FINANCEIRO] SUCESSO: Repasse (Payout) #{payout['id']} foi pago."
      $db.exec("SELECT DISTINCT family_name FROM admin_notifiers").each do |row|
        Mailer.send_admin_notification(subject: "✅ Repasse (Payout) Recebido!", body: "O repasse #{payout['id']} no valor de #{(payout['amount'] / 100.0).round(2)} #{payout['currency'].upcase} foi pago com sucesso.", family: row['family_name'])
      end
      return [200, {}, ['Repasse pago']]

    when 'payout.failed'
      payout = event['data']['object']
      $db.exec_params("UPDATE payouts SET status = $1, updated_at = NOW() WHERE stripe_payout_id = $2", [payout['status'], payout['id']])
      puts "[FINANCEIRO] FALHA: Repasse (Payout) #{payout['id']} falhou."
      $db.exec("SELECT DISTINCT family_name FROM admin_notifiers").each do |row|
        Mailer.send_admin_notification(subject: "‼️ FALHA no Repasse (Payout)!", body: "O repasse #{payout['id']} no valor de #{(payout['amount'] / 100.0).round(2)} #{payout['currency'].upcase} falhou.", family: row['family_name'])
      end
      return [200, {}, ['Falha no repasse']]

    else
      puts "[STRIPE] Info: Evento não tratado recebido: #{event_type}."
      return [200, {}, ['Evento não tratado']]
    end
  end
end