require 'stripe'
require 'json'
require 'time'

module StripeHandler
  # --- SETUP DA STRIPE, SEM SEGREDOS NO CÓDIGO ---
  Stripe.api_key = ENV['STRIPE_API_KEY']

  # --- FUNÇÃO DE MAPPING STRIPE PRICE -> SKU ---
  def self.stripe_price_to_sku_mapping
    mapping = {}
    $db.exec("SELECT stripe_price_id, sku FROM products WHERE stripe_price_id IS NOT NULL").each do |row|
      mapping[row['stripe_price_id']] ||= []
      mapping[row['stripe_price_id']] << row['sku']
    end
    mapping
  end

  # --- MAIN WEBHOOK HANDLER ---
  def self.handle_webhook(payload, sig_header)
    # --- SEGURANÇA: CHECAR VARS DE AMBIENTE E RETORNAR ERRO CLARO SE FALTAR ---
    unless ENV['STRIPE_API_KEY'] && ENV['STRIPE_WEBHOOK_SECRET']
      puts "‼️ Variáveis de ambiente Stripe faltando! Configure STRIPE_API_KEY e STRIPE_WEBHOOK_SECRET."
      return [500, {}, ['Configuração Stripe ausente']]
    end

    event = nil
    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, ENV['STRIPE_WEBHOOK_SECRET']
      )
    rescue JSON::ParserError => e
      puts "⚠️ JSON parse error: #{e.message}"
      return [400, {}, ['Invalid payload']]
    rescue Stripe::SignatureVerificationError => e
      puts "⚠️ Signature verification failed: #{e.message}"
      return [403, {}, ['Signature verification failed']]
    end

    # --- WEBHOOK PROCESSING ---
    case event['type']
    when 'checkout.session.completed'
      session = event['data']['object']
      # Lista dos line_items (produtos comprados)
      begin
        line_items_resp = Stripe::Checkout::Session.list_line_items(session['id'])
        line_items = line_items_resp['data']
      rescue => e
        puts "Erro buscando line_items: #{e.message}"
        return [500, {}, ['Erro ao buscar line_items']]
      end

      mapping = stripe_price_to_sku_mapping
      # Montar os SKUs válidos a partir do(s) price_id
      product_skus = []
      line_items.each do |item|
        price_id = (item['price'] && item['price']['id']) || item['price_id']
        skus = mapping[price_id] || []
        product_skus.concat(skus)
      end

      # Checagem de SKU
      if product_skus.empty? || product_skus.first.nil?
        puts "‼️ Nenhum SKU válido encontrado para os line_items (provavelmente price_id não cadastrado no banco). Não será gerada licença."
        return [500, {}, ['Nenhum SKU válido encontrado']]
      end

      expires_at = Time.now + (30 * 24 * 60 * 60)
      begin
        family = License.find_family_by_sku(product_skus.first)
        License.provision_license(
          email: session['customer_details']['email'],
          family: family,
          product_skus: product_skus.uniq,
          origin: 'stripe',
          status: 'active',
          expires_at: expires_at,
          platform_subscription_id: session['subscription']
        )
      rescue => e
        puts "‼️ Erro ao criar licença: #{e.message}"
        return [500, {}, ['Erro interno ao criar licença']]
      end
      [200, {}, ['Webhook processado com sucesso']]

    when 'invoice.payment_succeeded'
      # Implementar lógica caso queira.
      [200, {}, ['Pagamento confirmado']]
    else
      [200, {}, ['Evento não tratado']]
    end
  end
end
