require 'securerandom'
require 'date'
class License
  # ------------------------- LISTAGEM E UTILIDADES -----------------------------
  def self.filter(query: nil, origin: nil)
    sql = "SELECT * FROM licenses"
    params = []
    where_clauses = []
    if query && !query.empty?
      params << "%#{query}%"
      where_clauses << "(email ILIKE $#{params.length} OR license_key ILIKE $#{params.length} OR mac_address ILIKE $#{params.length})"
    end
    if origin && !origin.empty?
      params << origin
      where_clauses << "origin = $#{params.length}"
    end
    sql += " WHERE #{where_clauses.join(' AND ')}" unless where_clauses.empty?
    sql += " ORDER BY created_at DESC"
    $db.exec_params(sql, params)
  end
  def self.find_duplicate_subscriptions
    $db.exec(%Q{
      SELECT
        l.email,
        p.family,
        le.product_sku,
        COUNT(eg.id) AS grants_count
      FROM licenses l
      JOIN license_entitlements le ON l.id = le.license_id
      JOIN products p ON le.product_sku = p.sku
      JOIN entitlement_grants eg ON le.id = eg.license_entitlement_id
      WHERE l.status = 'active'
      GROUP BY l.email, p.family, le.product_sku
      HAVING COUNT(eg.id) > 1
      ORDER BY grants_count DESC
    })
  end
  def self.all_trial_attempts
    $db.exec('SELECT * FROM trial_attempts ORDER BY attempted_at DESC')
  end
  def self.find(id)
    result = $db.exec_params('SELECT * FROM licenses WHERE id = $1', [id])
    result.num_tuples > 0 ? result[0] : nil
  end
  def self.find_entitlements(license_id)
    $db.exec_params(%Q{
      SELECT p.name, eg.grant_source, eg.id as grant_id
      FROM products p
      JOIN license_entitlements le ON p.sku = le.product_sku
      JOIN entitlement_grants eg ON le.id = eg.license_entitlement_id
      WHERE le.license_id = $1 ORDER BY p.name
    }, [license_id])
  end
  def self.revoke(id)
    $db.exec_params("UPDATE licenses SET status = 'revoked' WHERE id = $1", [id])
  end
  def self.unlink_mac(id)
    $db.exec_params("UPDATE licenses SET mac_address = NULL WHERE id = $1", [id])
  end
  def self.delete(id)
    $db.exec_params("DELETE FROM licenses WHERE id = $1", [id])
  end
  def self.revoke_grant(grant_id)
    $db.exec_params("DELETE FROM entitlement_grants WHERE id = $1", [grant_id])
    $db.exec("DELETE FROM license_entitlements WHERE id NOT IN (SELECT DISTINCT license_entitlement_id FROM entitlement_grants)")
  end
  # -------- Checagem se já existe trial para email ou mac (qualquer status) na família --------
  def self.trial_exists?(email:, mac_address:, family:)
    result = $db.exec_params(
      "SELECT 1 FROM licenses
       WHERE family = $1
       AND origin = 'trial'
       AND (email = $2 OR mac_address = $3)
       LIMIT 1",
      [family, email, mac_address]
    )
    result.ntuples > 0
  end
  # --------------------------------- NOVO: Busca/Cria pelo par email+family --------------------------------
  def self.find_or_create_by_email_and_family(email, family, origin: "unknown", status: "active", expires_at: nil, mac_address: nil, platform_subscription_id: nil)
    license_result = $db.exec_params(
      "SELECT * FROM licenses WHERE email = $1 AND family = $2 LIMIT 1", [email, family]
    )
    if license_result.num_tuples > 0
      license = license_result[0]
      license_id = license['id']
      key = license['license_key']
      # PROTEÇÃO: NUNCA sobrescrever uma licença existente com "trial"
      if origin == 'trial'
        puts "[INFO] Tentativa de recriar trial bloqueada: já existe licença (ID: #{license_id}, origin: #{license['origin']}, status: #{license['status']}, email: #{license['email']}, family: #{license['family']})"
        return [license_id, key, false]
      end
      updates = []
      update_params = []
      # Atualização de origem/status só se vier de upgrade ou alteração real (Stripe, Pix, admin, etc)
      if origin && license['origin'] != origin
        updates << "origin = $#{update_params.size + 1}"
        update_params << origin
      end
      if status && license['status'] != status
        updates << "status = $#{update_params.size + 1}"
        update_params << status
      end
      if expires_at
        updates << "expires_at = $#{update_params.size + 1}"
        update_params << expires_at
      end
      if platform_subscription_id && (license['platform_subscription_id'].nil? || license['platform_subscription_id'] != platform_subscription_id)
        updates << "platform_subscription_id = $#{update_params.size + 1}"
        update_params << platform_subscription_id
      end
      if mac_address && (license['mac_address'].nil? || license['mac_address'] == '')
        updates << "mac_address = $#{update_params.size + 1}"
        update_params << mac_address
      end
      if updates.any?
        $db.exec_params(
          "UPDATE licenses SET #{updates.join(', ')} WHERE id = $#{update_params.size + 1}",
          update_params + [license_id]
        )
        puts "[INFO] Licença existente ID #{license_id} sobreposta: #{updates.join(', ')}"
      end
      [license_id, key, false]
    else
      key = generate_key_for_family(family)
      fields = %w(license_key email family status origin)
      values = [key, email, family, status, origin]
      placeholders = (1..fields.length).map { |i| "$#{i}" }
      if status == 'trial' && expires_at
        fields << 'trial_expires_at'
        values << expires_at
        placeholders << "$#{values.length}"
      elsif status == 'active' && expires_at
        fields << 'expires_at'
        values << expires_at
        placeholders << "$#{values.length}"
      end
      if mac_address
        fields << 'mac_address'
        values << mac_address
        placeholders << "$#{values.length}"
      end
      if platform_subscription_id
        fields << 'platform_subscription_id'
        values << platform_subscription_id
        placeholders << "$#{values.length}"
      end
      sql = "INSERT INTO licenses (#{fields.join(', ')}) VALUES (#{placeholders.join(', ')}) RETURNING id"
      result = $db.exec_params(sql, values)
      license_id = result[0]['id']
      [license_id, key, true]
    end
  end
  # -------------------- PROVISIONAMENTO CENTRALIZADO -------------------
 def self.provision_license(email:, family:, product_skus:, origin:, status: 'active', expires_at: nil, mac_address: nil, platform_subscription_id: nil, grant_source: nil)
  # BLOQUEIO trial antes de tudo
  if origin == 'trial' && trial_exists?(email: email, mac_address: mac_address, family: family)
    raise "Trial já utilizado para este email ou MAC nessa família"
  end
  conn = $db
  # Busca/cria de licença garantida pelo escopo email+family
  license_id, key, was_new = self.find_or_create_by_email_and_family(
    email, family,
    origin: origin,
    status: status,
    expires_at: expires_at,
    mac_address: mac_address,
    platform_subscription_id: platform_subscription_id
  )
  # Atualiza trial para ativo, se mudou no fluxo
  license_row = conn.exec_params("SELECT * FROM licenses WHERE id = $1", [license_id])[0]
  if license_row && license_row['status'] == 'trial' && status == 'active'
    conn.exec_params("UPDATE licenses SET status = 'active', trial_expires_at = NULL WHERE id = $1", [license_id])
  end
  # Expande SKUs caso família seja suite
  full_skus = expand_suites(product_skus, conn: conn)
  add_entitlements(
    license_id: license_id,
    product_skus: full_skus,
    grant_source: grant_source || "generic_#{origin}",
    conn: conn
  )

  # ------ ENVIO DE E-MAILS AUTOMÁTICO (AJUSTADO) -------
  if was_new || (status != 'trial')
    begin
      Mailer.send_license_email(
        to_email: email,
        license_key: key,
        type: (status == 'trial' ? :trial : :purchase)
      )
      Mailer.send_admin_notification(
        subject: "Licença #{was_new ? 'Criada' : 'Atualizada'} (#{origin})",
        body: "Licença #{was_new ? 'criada' : 'atualizada'} para #{email} na família '#{family}' (status: #{status}).\nKey: #{key}.\nSKUs: #{full_skus.join(', ')}.\nFonte: #{grant_source || "generic_#{origin}"}."
      )
    rescue => e
      puts "[ALERTA] Falha ao enviar e-mail automático: #{e.class} - #{e.message}"
    end
  end

  [license_id, key, was_new]
end

  # ---------------------- AUXILIARES / MÉTODOS DE SUPORTE -----------------------
  def self.expand_suites(product_skus, conn: $db)
    all_skus = product_skus.dup
    product_skus.each do |sku|
      components_result = conn.exec_params('SELECT component_product_id FROM suite_components WHERE suite_product_id = $1', [sku])
      if components_result.num_tuples > 0
        all_skus.concat(components_result.map { |row| row['component_product_id'] })
      end
    end
    all_skus.uniq
  end
  def self.generate_key_for_family(family_name)
    prefix = family_name.upcase.gsub(/[^A-Z0-9]/, '')
    random_part = Array.new(3) { SecureRandom.alphanumeric(4).upcase }.join('-')
    "#{prefix}-#{random_part}"
  end
  def self.add_entitlements(license_id:, product_skus:, grant_source:, conn: $db)
    product_skus.each do |sku|
      conn.exec_params(
        'INSERT INTO license_entitlements (license_id, product_sku) VALUES ($1, $2) ON CONFLICT (license_id, product_sku) DO NOTHING',
        [license_id, sku]
      )
      entitlement_result = conn.exec_params('SELECT id FROM license_entitlements WHERE license_id = $1 AND product_sku = $2', [license_id, sku])
      entitlement_id = entitlement_result[0]['id']
      conn.exec_params(
        'INSERT INTO entitlement_grants (license_entitlement_id, grant_source) VALUES ($1, $2)',
        [entitlement_id, grant_source]
      )
    end
  end
  def self.all_family_skus(family)
    res = $db.exec_params("SELECT sku FROM products WHERE family = $1", [family])
    res.map { |row| row['sku'] }
  end
  def self.family_product_names(family)
    res = $db.exec_params("SELECT name FROM products WHERE family = $1 ORDER BY name", [family])
    res.map { |row| row['name'] }
  end
  def self.family_purchase_link(family)
    res = $db.exec_params(%Q{
      SELECT pp.purchase_link FROM platform_products pp
      JOIN products p ON pp.product_sku = p.sku
      WHERE p.family = $1 AND pp.purchase_link IS NOT NULL AND pp.purchase_link != '' LIMIT 1
    }, [family])
    res.num_tuples > 0 ? res[0]['purchase_link'] : nil
  end
  def self.activate_license(license_id:)
    $db.exec_params("UPDATE licenses SET status = 'active', trial_expires_at = NULL WHERE id = $1", [license_id])
  end
  def self.find_family_by_sku(sku)
    result = $db.exec_params('SELECT family FROM products WHERE sku = $1 LIMIT 1', [sku])
    result.first && result.first['family']
  end
  def self.log_trial_denied(email:, mac_address:, product_sku:, reason:)
    $db.exec_params(
      "INSERT INTO trial_attempts (email, mac_address, product_sku, reason, attempted_at) VALUES ($1, $2, $3, $4, NOW())",
      [email, mac_address, product_sku, reason]
    )
    $db.exec_params(
      "INSERT INTO trial_email_counters (email, attempts, last_attempt_at)
       VALUES ($1, 1, NOW())
       ON CONFLICT (email)
       DO UPDATE SET attempts = trial_email_counters.attempts + 1, last_attempt_at = NOW()",
      [email]
    )
    $db.exec_params(
      "INSERT INTO trial_mac_counters (mac_address, attempts, last_attempt_at)
       VALUES ($1, 1, NOW())
       ON CONFLICT (mac_address)
       DO UPDATE SET attempts = trial_mac_counters.attempts + 1, last_attempt_at = NOW()",
      [mac_address]
    )
  end
end
