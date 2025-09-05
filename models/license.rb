# ---- models/license.rb (VERSÃO REATORIZADA E FINAL) ----

require 'securerandom'
require 'date'

class License

   def self.find_or_create_by_email_and_family(email, family)
    conn = $db
    result = conn.exec_params("SELECT * FROM licenses WHERE lower(email) = lower($1) AND lower(family) = lower($2) LIMIT 1", [email, family])
    if result.num_tuples > 0
      [result[0]['id'], result[0]['license_key'], false]
    else
      key = generate_key_for_family(family)
      insert_result = conn.exec_params("INSERT INTO licenses (license_key, email, family) VALUES ($1, $2, $3) RETURNING id, license_key", [key, email, family])
      [insert_result[0]['id'], insert_result[0]['license_key'], true]
    end
  end

  def self.trial_exists?(email:, mac_address:, family:)
    license_id_result = $db.exec_params("SELECT id FROM licenses WHERE (lower(email) = lower($1) OR mac_address = $2) AND lower(family) = lower($3) LIMIT 1", [email, mac_address, family])
    return false if license_id_result.num_tuples.zero?
    license_id = license_id_result[0]['id']
    result = $db.exec_params("SELECT 1 FROM license_entitlements WHERE license_id = $1 AND origin = 'trial' LIMIT 1", [license_id])
    result.ntuples > 0
  end

  def self.provision_license(email:, family:, product_skus:, origin:, grant_source:, trial_expires_at: nil, expires_at: nil, status: 'active', platform_subscription_id: nil, mac_address: nil, locale: nil, stripe_customer_id: nil, phone: nil)
    conn = $db
    license_id, key, was_new_license = find_or_create_by_email_and_family(email, family)

    conn.exec_params("UPDATE licenses SET stripe_customer_id = $1 WHERE id = $2", [stripe_customer_id, license_id]) if stripe_customer_id
    conn.exec_params("UPDATE licenses SET phone = $1 WHERE id = $2", [phone, license_id]) if phone && !phone.empty?
    conn.exec_params("UPDATE licenses SET locale = $1 WHERE id = $2 AND locale IS NULL", [locale, license_id]) if locale
    conn.exec_params("UPDATE licenses SET mac_address = $1 WHERE id = $2 AND mac_address IS NULL", [mac_address, license_id]) if mac_address

    if was_new_license
      begin
        puts "[EMAIL CAMADA 1] Chave nova criada. Enviando e-mail padrão com a chave."
        Mailer.send_license_email(to_email: email, license_key: key, family: family)
      rescue => e
        puts "[ALERTA] Falha ao enviar o e-mail padrão da chave de licença: #{e.class} - #{e.message}"
      end
    end

    if !was_new_license && origin == 'stripe'
      puts "[LICENSE] Cliente existente a comprar via Stripe. A desvincular MAC Address para flexibilidade de ativação."
      unlink_mac(license_id) 
    end

    full_product_skus = expand_suites(product_skus)

    full_product_skus.each do |sku|
      if platform_subscription_id
        existing = conn.exec_params("SELECT 1 FROM license_entitlements WHERE platform_subscription_id = $1 AND product_sku = $2 LIMIT 1", [platform_subscription_id, sku])
        if existing.num_tuples > 0
          puts "[IDEMPOTENCY] Direito de uso para SKU '#{sku}' e Assinatura '#{platform_subscription_id}' já existe. A pular."
          next
        end
      end
      entitlement_result = conn.exec_params(
        "INSERT INTO license_entitlements (license_id, product_sku, status, origin, expires_at, trial_expires_at, platform_subscription_id) VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id",
        [license_id, sku, status, origin, expires_at, trial_expires_at, platform_subscription_id]
      )
      entitlement_id = entitlement_result[0]['id']
      conn.exec_params("INSERT INTO entitlement_grants (license_entitlement_id, grant_source) VALUES ($1, $2)", [entitlement_id, grant_source])
    end

    begin
      trigger = nil
      # --- LÓGICA DE GATILHO ATUALIZADA ---
      # O gatilho para 'trial_started' agora é baseado na origem, não no status.
      if origin == 'trial'
        trigger = 'trial_started'
      elsif origin == 'stripe'
        trigger = 'subscription_started'
      elsif was_new_license && ['manual', 'beta', 'youtuber', 'suporte'].include?(origin)
        trigger = 'admin_grant_created'
      elsif !was_new_license && ['manual', 'beta', 'youtuber', 'suporte'].include?(origin)
        trigger = 'admin_grant_added'
      end

      if trigger
        puts "[EMAIL CAMADA 2] Gatilho '#{trigger}' detetado. A verificar regras de e-mail."
        trigger_customer_email(
          trigger_event: trigger, family: family, to_email: email, license_key: key,
          trial_end_date: trial_expires_at ? trial_expires_at.strftime('%d/%m/%Y') : '',
          granted_skus: full_product_skus
        )
      end

      Mailer.send_admin_notification(
        subject: "Nova Licença (#{origin}) para a família '#{family}'",
        body: "Direito de uso criado para #{email} na família '#{family}'. SKUs: #{full_product_skus.join(', ')}",
        family: family
      )
    rescue => e
      puts "[ALERTA] Falha no bloco de envio de e-mails (regras): #{e.class} - #{e.message}"
    end

    [license_id, key, was_new_license]
  end

  def self.update_entitlement_from_stripe(subscription_id:, new_expires_at:, new_status: 'active')
    $db.exec_params("UPDATE license_entitlements SET expires_at = $1, status = $2 WHERE platform_subscription_id = $3", [new_expires_at, new_status, subscription_id])
  end

  def self.update_entitlement_status_from_stripe(subscription_id:, status:)
    $db.exec_params("UPDATE license_entitlements SET status = $1 WHERE platform_subscription_id = $2", [status, subscription_id])
  end
  
  def self.unlink_mac(license_id)
    $db.exec_params("UPDATE licenses SET mac_address = NULL WHERE id = $1", [license_id])
  end

  def self.delete(license_id)
    $db.exec_params("DELETE FROM licenses WHERE id = $1", [license_id])
  end

  def self.revoke(license_id)
    $db.exec_params("UPDATE license_entitlements SET status = 'revoked' WHERE license_id = $1 AND status = 'active'", [license_id])
  end

  def self.delete_entitlement(entitlement_id)
    $db.exec_params("DELETE FROM license_entitlements WHERE id = $1", [entitlement_id])
  end
  
  def self.all_trial_attempts
    $db.exec('SELECT * FROM trial_attempts ORDER BY attempted_at DESC')
  end

  def self.log_trial_denied(email:, mac_address:, product_sku:, reason:)
    $db.exec_params("INSERT INTO trial_attempts (email, mac_address, product_sku, reason, attempted_at) VALUES ($1, $2, $3, $4, NOW())", [email, mac_address, product_sku, reason])
  end

  def self.generate_key_for_family(family_name)
    prefix = family_name.upcase.gsub(/[^A-Z0-9]/, '')
    random_part = Array.new(3) { SecureRandom.alphanumeric(4).upcase }.join('-')
    "#{prefix}-#{random_part}"
  end

  def self.find_family_by_sku(sku)
    result = $db.exec_params('SELECT family FROM products WHERE sku = $1 LIMIT 1', [sku])
    result.first && result.first['family']
  end

  def self.all_family_skus(family)
    res = $db.exec_params("SELECT sku FROM products WHERE family = $1", [family])
    res.map { |row| row['sku'] }
  end

  def self.expand_suites(product_skus)
    all_skus = product_skus.uniq.dup
    product_skus.uniq.each do |sku|
      components_result = $db.exec_params('SELECT component_product_id FROM suite_components WHERE suite_product_id = $1', [sku])
      if components_result.num_tuples > 0
        all_skus.concat(components_result.map { |row| row['component_product_id'] })
      end
    end
    all_skus.uniq
  end

  # --- MÉTODO DE SUMÁRIO ATUALIZADO (COM EMAIL_STATUS) ---
  def self.all_with_summary
    $db.exec(%q{
      SELECT
        licenses.*,
        licenses.email_status,
        COALESCE(
          -- 1. Procura por um status 'Ativo' (pago, origem diferente de trial).
          (SELECT 'Ativo' FROM license_entitlements le
           WHERE le.license_id = licenses.id AND le.status = 'active' AND le.origin != 'trial' LIMIT 1),
           
          -- 2. Se não for pago, procura por um 'Trial' ainda válido, baseado na ORIGEM.
          (SELECT 'Trial' FROM license_entitlements le
           WHERE le.license_id = licenses.id AND le.origin = 'trial' AND le.status = 'active'
           AND (le.trial_expires_at > NOW()) LIMIT 1),
           
          -- 3. Se não encontrar nenhum dos dois, a licença é 'Inativo'.
          'Inativo'
        ) AS summary_status,
        
        -- A lista de origens (mostra todas as que estão ativas).
        (SELECT string_agg(DISTINCT le.origin, ', ')
         FROM license_entitlements le
         WHERE le.license_id = licenses.id AND le.status = 'active') AS summary_origins
      FROM
        licenses
      ORDER BY
        licenses.id DESC
    })
  end
  
  private_class_method def self.trigger_customer_email(trigger_event:, family:, to_email:, license_key: nil, trial_end_date: '', granted_skus: [])
    rule_check = $db.exec_params(%q{
      SELECT
        t.subject, t.body,
        f.display_name, f.homepage_url, f.support_email, f.logo_url, f.sender_name
      FROM email_rules r
      JOIN email_templates t ON r.email_template_id = t.id
      JOIN product_family_info f ON r.family_name = f.family_name
      WHERE r.family_name = $1 AND t.trigger_event = $2 AND r.is_active = true
      LIMIT 1
    }, [family, trigger_event])

    return if rule_check.num_tuples.zero?

    email_data = rule_check.first

    subject = email_data['subject'].gsub('{{product_family}}', email_data['display_name'] || family.capitalize)
    body = email_data['body']

    body.gsub!('{{license_key}}', license_key.to_s)
    body.gsub!('{{trial_end_date}}', trial_end_date.to_s)
    body.gsub!('{{product_family}}', email_data['display_name'] || family.capitalize)
    body.gsub!('{{family_homepage_url}}', email_data['homepage_url'] || '#')
    body.gsub!('{{family_support_email}}', email_data['support_email'] || 'suporte@maniaa.com.br')
    
    # Removemos a variável de logo que não é mais usada
    # body.gsub!('{{family_logo_url}}', email_data['logo_url'] || '') 

    if body.include?('{{granted_products_list}}') && !granted_skus.empty?
      product_names_result = $db.exec_params(
        "SELECT name FROM products WHERE sku = ANY($1::varchar[]) ORDER BY name",
        [granted_skus]
      )
      if product_names_result.num_tuples > 0
        list_html = "<ul>"
        product_names_result.each { |prod| list_html << "<li>#{prod['name']}</li>" }
        list_html << "</ul>"
        body.gsub!('{{granted_products_list}}', list_html)
      end
    end

    if body.include? '{{family_purchase_links}}'
      links_html = ""
      products_in_family = $db.exec_params(
        "SELECT p.name, pp.purchase_link FROM products p
         JOIN platform_products pp ON p.sku = pp.product_sku
         WHERE p.family = $1 AND pp.purchase_link IS NOT NULL AND pp.purchase_link != ''
         ORDER BY p.name",
        [family]
      )

      if products_in_family.num_tuples > 0
        links_html << "<ul>"
        products_in_family.each { |prod| links_html << "<li><a href='#{prod['purchase_link']}'>Comprar #{prod['name']}</a></li>" }
        links_html << "</ul>"
      end
      body.gsub!('{{family_purchase_links}}', links_html)
    end

    puts "[EMAIL] Disparando e-mail de cliente para '#{to_email}' via gatilho '#{trigger_event}'"
    Mailer.send_license_email(
      to_email: to_email,
      subject: subject,
      body: body,
      sender_name: email_data['sender_name']
    )
  end

end