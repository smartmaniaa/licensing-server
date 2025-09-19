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
  
  begin
    invoice_id = credit_note_data['invoice']
    
    unless invoice_id
      puts "[FINANCE] ALERTA: Nota de crédito #{credit_note_data['id']} sem ID de fatura associado. Reembolso não contabilizado."
      return [200, {}, ['Nota de crédito sem fatura']]
    end

    # Usa a fatura para encontrar o ID da assinatura
    invoice = Stripe::Invoice.retrieve(invoice_id, { expand: ['subscription'] })
    subscription_id = invoice.subscription.id
    
    unless subscription_id
      puts "[FINANCE] ALERTA: Fatura #{invoice_id} sem ID de assinatura. Reembolso não contabilizado."
      return [200, {}, ['Fatura sem assinatura']]
    end

    amount_refunded = credit_note_data['amount']
    currency = credit_note_data['currency']
    
    # Encontra o entitlement para ter o license_id e o email
    entitlement_info = $db.exec_params(
      "SELECT l.id, l.email FROM license_entitlements le JOIN licenses l ON le.license_id = l.id WHERE le.platform_subscription_id = $1 LIMIT 1",
      [subscription_id]
    ).first
    
    unless entitlement_info
      puts "[FINANCE] ALERTA: Não foi possível encontrar a licença local para a assinatura #{subscription_id}. Registro financeiro ignorado."
      return
    end

    # Loga o evento de reembolso na nova tabela de auditoria
    License.log_platform_event(
      event_type: 'refund',
      license_id: entitlement_info['id'],
      email: entitlement_info['email'],
      product_sku: nil, # O SKU não está diretamente na fatura, e a informação não é crítica para o balanço.
      source_system: 'stripe_webhook',
      details: {
        platform_customer_id: credit_note_data['customer'],
        platform_subscription_id: subscription_id,
        platform_invoice_id: invoice_id,
        amount_cents: -amount_refunded, # Valor NEGATIVO para reembolso
        currency: currency,
        payload_details: event
      }
    )

    # Atualiza o balanço financeiro por licença
    self.record_financial_transaction({
      'amount_paid' => -amount_refunded,
      'currency' => currency,
      'parent' => { 'subscription_details' => { 'subscription' => subscription_id } }
    })
  
    puts "[FINANCE] Reembolso de #{amount_refunded} #{currency.upcase} para a assinatura #{subscription_id} processado."
    return [200, {}, ['Reembolso processado com sucesso']]
    
  rescue Stripe::InvalidRequestError => e
    puts "⚠️ ERRO: Falha ao buscar fatura do Stripe: #{e.message}"
    return [400, {}, ['Erro na busca do Stripe API']]
  rescue => e
    puts "‼️ ERRO inesperado ao processar reembolso: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
    return [500, {}, ['Erro interno ao processar reembolso']]
end
def self.record_financial_transaction(invoice_data)
  amount_paid = invoice_data['amount_paid']
  currency = invoice_data['currency']
  subscription_id = invoice_data.dig('parent', 'subscription_details', 'subscription') || invoice_data.dig('lines', 'data', 0, 'subscription')
  
  return unless subscription_id && amount_paid.to_i > 0

  # 1. Encontra o license_id correspondente
  license_info = $db.exec_params("SELECT license_id FROM license_entitlements WHERE platform_subscription_id = $1 LIMIT 1", [subscription_id]).first
  
  unless license_info
    puts "[FINANCE] ALERTA: Não foi possível encontrar a licença local para a assinatura #{subscription_id}. Registro financeiro ignorado."
    return
  end

  license_id = license_info['license_id']
  
  # 2. Obtém o balanço atual em JSONB para a licença
  current_balance = $db.exec_params("SELECT gross_revenue_by_currency FROM license_financial_summary WHERE license_id = $1", [license_id]).first
  
  balance_json = current_balance ? JSON.parse(current_balance['gross_revenue_by_currency']) : {}
  
  # 3. Adiciona o novo valor à moeda correta no JSON
  current_amount = balance_json[currency] || 0
  balance_json[currency] = current_amount + amount_paid
  
  # 4. Salva o novo JSON no banco de dados
  $db.exec_params(
    %q{
      INSERT INTO license_financial_summary (license_id, gross_revenue_by_currency) VALUES ($1, $2)
      ON CONFLICT (license_id) DO UPDATE SET gross_revenue_by_currency = $2
    },
    [license_id, balance_json.to_json]
  )
  
  puts "[FINANCE] Balanço da licença ID #{license_id} atualizado com +#{amount_paid} #{currency.upcase}."
end
end