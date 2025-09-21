# ---- server.rb (VERSÃO ABSOLUTAMENTE COMPLETA E FINAL) ----

require 'sinatra/base'
require 'pg'
require 'json'
require 'csv'
require 'dotenv/load'
require 'sendgrid-ruby'
require_relative 'models/license.rb'
require_relative 'models/product.rb'
require_relative 'mailer.rb'
require_relative 'stripe_config.rb'
require_relative 'stripe_handler.rb'
$stdout.sync = true

class SmartManiaaApp < Sinatra::Base
  set :bind, '0.0.0.0'
  
  before do
    # Garante que a conexão com o banco de dados esteja sempre ativa.
    begin
      $db.exec("SELECT 1")
    rescue PG::Error => e
      puts "[DB] Conexão com o banco de dados perdida. Tentando reconectar... Erro original: #{e.message}"
      $db = PG.connect(ENV['DATABASE_URL'], sslmode: 'require')
      puts "[DB] Reconectado com sucesso!"
    end

    # Bloco de debug de headers.
    puts "========= DEBUG HEADERS ========"
    puts "Host do request: #{request.host.inspect}"
    puts "Path: #{request.path_info}"
    puts "================================="
  end

  use Rack::MethodOverride
  enable :sessions
  set :session_secret, ENV.fetch("SESSION_SECRET")
  
  configure do
    retries = 5
    begin
      if ENV['DATABASE_URL']
        $db = PG.connect(ENV['DATABASE_URL'], sslmode: 'require')
        puts "=> Conectado ao banco de dados via DATABASE_URL!"
      else
        $db = PG.connect(
          host: ENV.fetch('DATABASE_HOST', 'localhost'),
          dbname: ENV.fetch('DATABASE_NAME', 'smartmaniaa_licensing_dev'),
          user: ENV.fetch('DATABASE_USER', 'postgres'),
          password: ENV.fetch('DATABASE_PASSWORD') 
        )
        puts "=> Conectado ao banco de dados local/Docker com sucesso!"
      end
    rescue PG::ConnectionBad, PG::Error => e
      retries -= 1
      if retries > 0
        puts "Falha ao conectar ao banco de dados. Tentando novamente em 5 segundos..."
        sleep 5
        retry
      else
        puts "ERRO: Falha ao conectar ao banco de dados: #{e.message}"
        raise e
      end
    end
  end

  helpers do
    def protected!
      return if authorized?
      headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
      halt 401, "Not authorized\n"
    end

    def authorized?
      @auth ||= Rack::Auth::Basic::Request.new(request.env)
      @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == [ENV['ADMIN_USER'], ENV['ADMIN_PASSWORD']]
    end

    def build_phone_from_params(params)
      return nil unless params['phone_number'] && !params['phone_number'].strip.empty?
      country_code = params['country_code']
      country_code = params['other_country_code']&.strip if country_code.empty?
      return nil unless country_code && !country_code.empty?
      country_code = "+#{country_code.gsub(/\D/, '')}" unless country_code.start_with?('+')
      cleaned_number = params['phone_number'].gsub(/\D/, '')
      "#{country_code}#{cleaned_number}"
    end

  end

  # Tornando o método de log acessível para outros módulos
  def self.log_event(level:, source:, message:, details: nil)
   # A correção é feita aqui: convertendo o hash para JSON antes de escapar
   details_json = details ? details.to_json : nil
  
   # A linha abaixo já está usando a interpolação segura do PostgreSQL
   $db.exec_params(
     "INSERT INTO system_events (level, source, message, details) VALUES ($1, $2, $3, $4)",
     [level.to_s.upcase, source, message, details_json]
   )
 end

  # --- ROTAS PÚBLICAS ---
  get '/' do
    content_type :json
    { status: "API de Licenciamento SmartManiaa no ar!" }.to_json
  end

  post '/webhook/stripe' do
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    result = StripeHandler.handle_webhook(payload, sig_header)
    status result[0]
    headers result[1] if result[1]&.any?
    body Array(result[2]).join
  end

  post '/start_trial' do
    content_type :json
    begin
      params = JSON.parse(request.body.read)
    rescue JSON::ParserError
      halt 400, { error: 'Invalid JSON' }.to_json
    end

    email = params['email']
    mac_address = params['mac_address']
    product_sku = params['product_sku']
    phone = params['phone']

    family = License.find_family_by_sku(product_sku)
    unless family
      halt 404, { error: "Produto com SKU '#{product_sku}' não encontrado.", status: "invalid_sku" }.to_json
    end

    if License.trial_exists?(email: email, mac_address: mac_address, family: family)
      License.log_trial_denied(email: email, mac_address: mac_address, product_sku: product_sku, reason: "Trial já utilizado para este e-mail ou MAC na família #{family}")
      puts "[TRIAL] Negado: Tentativa de novo trial para '#{email}' ou MAC '#{mac_address}' que já possui histórico."
      begin
        License.send(:trigger_customer_email, trigger_event: 'trial_denied', family: family, to_email: email)
      rescue => e
        puts "[ALERTA] Falha ao enviar e-mail de trial negado: #{e.class} - #{e.message}"
      end
      halt 403, { error: "Trial já existe para este email ou MAC.", status: "denied" }.to_json
    end

    family_info = $db.exec_params("SELECT trial_duration_days FROM product_family_info WHERE family_name = $1", [family]).first
    trial_days = (family_info && family_info['trial_duration_days'].to_i > 0) ? family_info['trial_duration_days'].to_i : 7
    puts "[TRIAL] Duração definida para #{trial_days} dia(s) para a família '#{family}'."
    
    family_skus = License.all_family_skus(family)
    expires_at = (Time.now + trial_days * 24 * 60 * 60)

    _license_id, key, _was_new = License.provision_license(
      email: email, family: family, product_skus: family_skus, origin: 'trial',
      status: 'active', trial_expires_at: expires_at, mac_address: mac_address,
      grant_source: "trial_#{family}", phone: phone
    )
    puts "[TRIAL] Sucesso: Trial iniciado para '#{email}' no MAC '#{mac_address}'."
    { license_key: key, status: "trial_started", expires_at: expires_at }.to_json
  end

post '/validate' do
    content_type :json
    begin
      params = JSON.parse(request.body.read)
    rescue JSON::ParserError
      halt 400, { error: 'Invalid JSON' }.to_json
    end

    key = params['license_key']
    mac = params['mac_address']
    sku = params['product_sku']
    client_version = params['product_version'] # <-- NOVO PARÂMETRO ESPERADO

    license_result = $db.exec_params("SELECT * FROM licenses WHERE license_key = $1 LIMIT 1", [key])
    if license_result.num_tuples.zero?
      return { status: 'invalid', message: 'Chave de licença não encontrada.' }.to_json
    end
    license = license_result.first

    entitlement_result = $db.exec_params(
      %Q{
        SELECT * FROM license_entitlements
        WHERE license_id = $1 AND product_sku = $2 AND status IN ('active', 'pending_cancellation', 'awaiting_payment')
        AND (
          (origin != 'trial' AND (expires_at > NOW() OR expires_at IS NULL)) OR
          (origin = 'trial' AND trial_expires_at > NOW())
        )
        LIMIT 1
      },
      [license['id'], sku]
    )

    if entitlement_result.num_tuples.zero?
      return { status: 'invalid', message: "Nenhum direito de uso ativo encontrado para este produto." }.to_json
    end

    if license['mac_address'].nil?
      $db.exec_params("UPDATE licenses SET mac_address = $1 WHERE id = $2", [mac, license['id']])
    elsif license['mac_address'] != mac
      return { status: 'invalid', message: "Chave já vinculada a outro computador." }.to_json
    end
    
    # --- NOVA LÓGICA DE VERIFICAÇÃO DE VERSÃO E LINK ---
    product_info = Product.find(sku)
    
    update_available = false
    latest_version = product_info['latest_version']
    
    if client_version && latest_version && !latest_version.empty? && client_version != latest_version
      update_available = true
    end

    # Monta a resposta final
    response = {
      status: 'valid',
      message: 'Licença válida.'
    }
    
    if update_available
      response[:latest_version] = latest_version
      response[:update_url] = product_info['download_link']
    end

    response.to_json
  end
  
  # --- ROTAS DE TESTE ---
  get '/admin/create_suite_test' do
    content_type :json
    email_teste = "teste-#{Time.now.to_i}@smartmaniaa.com.br"
    produtos_da_suite_result = $db.exec("SELECT sku FROM products WHERE family = 'smartgrid'")
    produtos_da_suite = produtos_da_suite_result.map { |row| row['sku'] }
    family = License.find_family_by_sku(produtos_da_suite.first)
    License.provision_license(
      email: email_teste, family: family, product_skus: produtos_da_suite,
      origin: 'manual_test', grant_source: 'suite_test_button', status: 'active'
    )
    { message: "Chave de licença para a Suite completa gerada com sucesso" }.to_json
  end

  post '/test_stripe_webhook' do
    content_type :json
    payload = request.body.read
    puts "[DEBUG] Corpo da requisição recebido na rota de teste:"
    puts payload
    begin
      StripeHandler.handle_webhook(payload, "dummy_signature_for_test")
      { status: 'ok', message: 'Simulação de webhook processada.' }.to_json
    rescue => e
      puts "‼️ ERRO INESPERADO na rota /test_stripe_webhook: #{e.class} - #{e.message}"
      halt 500, { error: "Erro interno no servidor: #{e.message}" }.to_json
    end
  end

  # --- ROTAS DO PAINEL DE ADMIN ---

  post '/admin/logs/clear' do
  protected!
  begin
    $db.exec("TRUNCATE TABLE system_events RESTART IDENTITY")
    SmartManiaaApp.log_event(
      level: 'info',
      source: 'admin',
      message: 'Registros de logs de auditoria foram limpos.',
      details: { user: ENV['ADMIN_USER'] }
    )
    puts "[ADMIN] Registros da tabela 'system_events' foram truncados."
    session[:notice] = "Os registros de logs de auditoria foram limpos com sucesso!"
  rescue PG::Error => e
    puts "[ADMIN] ERRO ao tentar limpar os logs: #{e.message}"
    session[:error] = "Erro ao tentar limpar os logs: #{e.message}"
  end
  redirect request.referer || '/admin/audit_log'
end

get '/admin/logs/export.csv' do
  protected!
  logs = $db.exec("SELECT * FROM system_events ORDER BY created_at DESC")
  content_type 'text/csv'
  attachment "logs-smartmaniaa-#{Time.now.strftime('%Y%m%d')}.csv"
  CSV.generate(col_sep: ';') do |csv|
    csv << ["Data/Hora", "Nível", "Fonte", "Mensagem", "Detalhes"]
    logs.each do |log|
      details_str = log['details'] ? JSON.pretty_generate(JSON.parse(log['details'])) : ''
      csv << [
        Time.parse(log['created_at']).strftime('%d/%m/%Y %H:%M'),
        log['level'],
        log['source'],
        log['message'],
        details_str
      ]
    end
  end
end

get '/admin' do
  protected!
  @licenses = License.all_with_summary
  
  # --- INÍCIO DA NOVA LÓGICA: BALANÇO FINANCEIRO ---
  @financials_by_license = {}
  $db.exec("SELECT license_id, gross_revenue_by_currency FROM license_financial_summary").each do |row|
    @financials_by_license[row['license_id'].to_i] = JSON.parse(row['gross_revenue_by_currency'])
  end
  # --- FIM DA NOVA LÓGICA ---
  
  erb :admin_dashboard
end

  # --- ROTAS DE GERENCIAMENTO DE PRODUTOS ---
  get '/admin/products' do
    protected!
    @products = Product.all
    @error = session.delete(:error)
    erb :admin_products
  end

  get '/admin/products/new' do
    protected!
    @error = session.delete(:error)
    erb :admin_new_product
  end

post '/admin/products' do
  protected!
  success = Product.create(
    sku: params['sku'], 
    name: params['name'], 
    family: params['family'],
    latest_version: params['latest_version'],
    download_link: params['download_link'] # Adicione esta linha
  )
  if success
    new_family = params['family']
    admin_email = Mailer::ADMIN_EMAIL
    notifiers_exist_result = $db.exec_params("SELECT 1 FROM admin_notifiers WHERE family_name = $1 LIMIT 1", [new_family])
    if notifiers_exist_result.num_tuples.zero?
      $db.exec_params(
        "INSERT INTO admin_notifiers (email, family_name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        [admin_email, new_family]
      )
      puts "[ADMIN] Família '#{new_family}' detectada como nova. Notificador padrão '#{admin_email}' adicionado."
    end
    Product.save_platform_product(
      sku: params['sku'], platform: 'stripe', platform_id: params['platform_id'], link: params['purchase_link']
    )
    redirect '/admin/products'
  else
    session[:error] = "Falha ao criar o produto. O SKU ou o Nome do Produto já existem."
    redirect '/admin/products/new'
  end
end

  get '/admin/product/:sku/edit' do
    protected!
    product_sku = params['sku']
    @product = Product.find(product_sku)
    @platform_product = Product.find_platform_products_for_sku(product_sku)[0] || {}
    @all_other_products = $db.exec_params('SELECT * FROM products WHERE sku != $1 AND family = $2 ORDER BY name', [product_sku, @product['family']])
    @suite_components = Product.find_suite_components(product_sku)
    @error = session.delete(:error)
    erb :admin_edit_product
  end

post '/admin/product/:sku' do
  protected!
  product_sku = params['sku']
  Product.update(
    sku: product_sku, 
    name: params['name'], 
    family: params['family'],
    latest_version: params['latest_version'],
    download_link: params['download_link'] # Adicione esta linha
  )
  Product.save_platform_product(sku: product_sku, platform: 'stripe', platform_id: params['platform_id'], link: params['purchase_link'])
  component_skus = params['component_skus'] || []
  Product.update_suite_components(suite_sku: product_sku, component_skus: component_skus)
  redirect '/admin/products'
end

  post '/admin/product/:sku/delete' do
    protected!
    Product.delete(params['sku'])
    redirect '/admin/products'
  end

  post '/admin/family/:name/delete' do
    protected!
    family_name = params['name']

    puts "[ADMIN] Iniciando exclusão completa da família: #{family_name}"

    $db.transaction do |conn|
      product_skus_res = conn.exec_params("SELECT sku FROM products WHERE family = $1", [family_name])
      product_skus = product_skus_res.map { |row| row['sku'] }

      if product_skus.any?
        license_ids_res = conn.exec_params("SELECT id FROM licenses WHERE family = $1", [family_name])
        license_ids = license_ids_res.map { |row| row['id'] }

        if license_ids.any?
          license_ids_sql_list = license_ids.join(',')
          entitlement_ids_res = conn.exec("SELECT id FROM license_entitlements WHERE license_id IN (#{license_ids_sql_list})")
          entitlement_ids = entitlement_ids_res.map { |row| row['id'] }
          if entitlement_ids.any?
            entitlement_ids_sql_list = entitlement_ids.join(',')
            conn.exec("DELETE FROM entitlement_grants WHERE license_entitlement_id IN (#{entitlement_ids_sql_list})")
          end
          conn.exec("DELETE FROM license_entitlements WHERE license_id IN (#{license_ids_sql_list})")
        end
        product_skus_sql_list = product_skus.map { |sku| "'#{conn.escape_string(sku)}'" }.join(',')
        conn.exec("DELETE FROM trial_attempts WHERE product_sku IN (#{product_skus_sql_list})")
        conn.exec_params("DELETE FROM licenses WHERE family = $1", [family_name])
        conn.exec("DELETE FROM suite_components WHERE suite_product_id IN (#{product_skus_sql_list}) OR component_product_id IN (#{product_skus_sql_list})")
        conn.exec("DELETE FROM platform_products WHERE product_sku IN (#{product_skus_sql_list})")
      end
      conn.exec_params("DELETE FROM products WHERE family = $1", [family_name])
      conn.exec_params("DELETE FROM email_rules WHERE family_name = $1", [family_name])
      conn.exec_params("DELETE FROM admin_notifiers WHERE family_name = $1", [family_name])
      conn.exec_params("DELETE FROM product_family_info WHERE family_name = $1", [family_name])
    end

    puts "[ADMIN] Família #{family_name} e todos os seus dados foram excluídos com sucesso."
    redirect '/admin/families'
  end

  # --- ROTAS DE GERENCIAMENTO DE LICENÇAS ---
  get '/admin/new' do
  protected!
  all_products = Product.all
  @families = all_products.map { |p| p['family'] }.uniq.sort 
  @products_by_family = all_products.group_by { |p| p['family'] }.to_json
  # LINHA ADICIONADA:
  @origins = $db.exec("SELECT * FROM manual_license_origins ORDER BY display_name")
  erb :admin_new_license
end

  post '/admin/create' do
    protected!
    email = params['email']
    product_skus = params['product_skus']
    origin = params['origin']
    expires_at = params['expires_at']
    expires_at = expires_at.empty? ? nil : Time.parse(expires_at)
    
    phone = build_phone_from_params(params)

    if product_skus.nil? || product_skus.empty?
      halt 400, "Erro: Você deve selecionar pelo menos um produto."
    end
    
    if product_skus.length > 1
      families = $db.exec_params("SELECT DISTINCT family FROM products WHERE sku = ANY($1::varchar[])", ["{#{product_skus.join(',')}}"])
      if families.num_tuples > 1
        halt 400, "Erro: Todos os produtos selecionados devem pertencer à mesma família."
      end
    end
    
    family = License.find_family_by_sku(product_skus.first)
    
    License.provision_license(
      email: email, 
      family: family, 
      product_skus: product_skus, 
      origin: origin,
      status: 'active', 
      expires_at: expires_at, 
      grant_source: "manual_admin_#{origin}",
      phone: phone
    )

    puts "[ADMIN] Licença manual criada para '#{email}' com os SKUs: #{product_skus.join(', ')}."
    redirect '/admin'
  end

get '/admin/license/:id' do
  protected!
  license_id = params['id']
  @license = $db.exec_params("SELECT * FROM licenses WHERE id = $1", [license_id]).first
  
  @entitlements = $db.exec_params(
    "SELECT le.*, p.name AS product_name 
     FROM license_entitlements le JOIN products p ON le.product_sku = p.sku
     WHERE le.license_id = $1 ORDER BY le.id DESC", 
    [license_id]
  ).to_a 

  # --- INÍCIO DA NOVA LÓGICA: BALANÇO POR CHAVE ---
  @financial_summary = $db.exec_params(
    "SELECT gross_revenue_by_currency FROM license_financial_summary WHERE license_id = $1",
    [license_id]
  ).first
  # --- FIM DA NOVA LÓGICA ---

  erb :license_detail
end

  post '/admin/license/:id/revoke' do
    protected!
    License.revoke(params['id'])
    puts "[ADMIN] Todos os direitos de uso ativos da Licença ID #{params['id']} foram revogados."
    redirect "/admin/license/#{params['id']}"
  end

  post '/admin/license/:id/unlink_mac' do
    protected!
    License.unlink_mac(params['id'])
    puts "[ADMIN] MAC Address foi desvinculado da Licença ID #{params['id']}."
    redirect "/admin/license/#{params['id']}"
  end

  post '/admin/license/:id/delete' do
    protected!
    License.delete(params['id'])
    puts "[ADMIN] Licença ID #{params['id']} e todos os seus dados associados foram deletados."
    redirect '/admin'
  end
  
  post '/admin/license/:id/phone' do
    protected!
    license_id = params['id']
    full_phone = build_phone_from_params(params)
    $db.exec_params("UPDATE licenses SET phone = $1 WHERE id = $2", [full_phone, license_id])
    puts "[ADMIN] Telefone da Licença ID #{license_id} foi atualizado."
    redirect "/admin/license/#{license_id}"
  end

  post '/admin/entitlement/:id/delete' do
    protected!
    entitlement_id = params['id']
    license_id = params['license_id']
    License.delete_entitlement(entitlement_id)
    puts "[ADMIN] Direito de uso ID #{entitlement_id} foi deletado."
    redirect "/admin/license/#{license_id}"
  end

  # --- ROTAS DE GERENCIAMENTO DE TRIALS ---
  get '/admin/trials' do
  protected!
  @attempts = $db.exec(%q{
    SELECT * FROM platform_license_events_audit
    WHERE event_type = 'trial_denied'
    ORDER BY recorded_at DESC
  })
  erb :admin_trial_attempts
end
  
  post '/admin/trials/clear' do
   protected!
   # Substitua a linha antiga pela nova:
   $db.exec_params("DELETE FROM platform_license_events_audit WHERE event_type = 'trial_denied'")
   session[:notice] = "Os registros de tentativas de trial negadas foram apagados!"
   redirect '/admin/trials'
 end

  # --- ROTAS PARA AUDITORIA DE EVENTOS ---
 get '/admin/audit_log' do
   protected!
   # Filtra os logs para exibir apenas eventos de negócio relevantes
   @audit_logs = $db.exec(%q{
     SELECT * FROM system_events
     WHERE
       source != 'sendgrid_webhook' AND
       source != 'admin'
     ORDER BY created_at DESC
   })
 
   erb :admin_audit_log
 end

  get '/admin/audit_log/export.csv' do
    protected!
    events = $db.exec("SELECT * FROM platform_license_events_audit ORDER BY recorded_at DESC")
    content_type 'text/csv'
    headers 'Content-Disposition' => "attachment; filename=\"log_auditoria_smartmaniaa_#{Time.now.strftime('%Y%m%d')}.csv\""
    CSV.generate do |csv|
      csv << events.fields # Cabeçalhos
      events.each do |event|
        csv << event.values # Valores das linhas
      end
    end
  end

  # --- ROTAS DO CENTRO DE CONTROLE DA FAMÍLIA ---
  get '/admin/families' do
    protected!
    $db.exec(%q{
      INSERT INTO product_family_info (family_name, homepage_url, display_name)
      SELECT DISTINCT family, '', INITCAP(family) FROM products
      WHERE family NOT IN (SELECT family_name FROM product_family_info)
    })
    
    $db.exec(%q{
      DELETE FROM product_family_info
      WHERE family_name NOT IN (SELECT DISTINCT family FROM products)
    })
    
    @families = $db.exec("SELECT * FROM product_family_info ORDER BY family_name")
    erb :admin_families
  end

  get '/admin/family/:name' do
    protected!
    @family_name = params['name']
    
    @family_info = $db.exec_params("SELECT * FROM product_family_info WHERE family_name = $1", [@family_name]).first
    halt 404, "Família não encontrada" unless @family_info

    @notifiers = $db.exec_params("SELECT * FROM admin_notifiers WHERE family_name = $1 ORDER BY email", [@family_name])
    @templates = $db.exec("SELECT * FROM email_templates ORDER BY name")
    @rules = {}
    $db.exec_params("SELECT * FROM email_rules WHERE family_name = $1", [@family_name]).each do |rule|
      @rules[rule['email_template_id']] = rule['is_active'] == 't'
    end

    erb :admin_family_settings
  end

  post '/admin/family/:name' do
  protected!
  family_name = params['name']

  # Query UPDATE modificada para incluir a nova coluna 'download_page_url'
  $db.exec_params(
    "UPDATE product_family_info SET display_name = $1, homepage_url = $2, support_email = $3, sender_name = $4, trial_duration_days = $5, download_page_url = $6 WHERE family_name = $7",
    [
      params['display_name'], 
      params['homepage_url'], 
      params['support_email'], 
      params['sender_name'], 
      params['trial_duration_days'],
      params['download_page_url'], # Novo parâmetro
      family_name
    ]
  )

  if params['new_notifier_email'] && !params['new_notifier_email'].empty?
    $db.exec_params(
      "INSERT INTO admin_notifiers (email, family_name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
      [params['new_notifier_email'], family_name]
    )
  end

  (params['remove_notifiers'] || []).each do |email_to_remove|
    $db.exec_params("DELETE FROM admin_notifiers WHERE email = $1 AND family_name = $2", [email_to_remove, family_name])
  end

  template_ids = $db.exec("SELECT id FROM email_templates").map { |row| row['id'] }
  template_ids.each do |template_id|
    is_active_from_form = params['rules'] && params['rules'][template_id] == 'on'
    
    existing_rule = $db.exec_params("SELECT id FROM email_rules WHERE family_name = $1 AND email_template_id = $2", [family_name, template_id]).first

    if existing_rule
      $db.exec_params("UPDATE email_rules SET is_active = $1 WHERE id = $2", [is_active_from_form, existing_rule['id']])
    elsif is_active_from_form
      $db.exec_params("INSERT INTO email_rules (family_name, email_template_id, is_active) VALUES ($1, $2, true)", [family_name, template_id])
    end
  end

  redirect "/admin/family/#{family_name}"
end

  get '/admin/email_templates/new' do
    protected!
    erb :admin_email_template_new
  end

  post '/admin/email_templates' do
    protected!
    $db.exec_params("INSERT INTO email_templates (name, trigger_event, subject, body) VALUES ($1, $2, $3, $4)", [params['name'], params['trigger_event'], params['subject'], params['body']])
    puts "[ADMIN] Novo template de e-mail '#{params['name']}' foi criado."
    redirect '/admin/families'
  end

  get '/admin/email_templates/:id/edit' do
    protected!
    @template = $db.exec_params("SELECT * FROM email_templates WHERE id = $1", [params['id']]).first
    erb :admin_email_template_edit
  end

  post '/admin/email_templates/:id' do
    protected!
    $db.exec_params(
      "UPDATE email_templates SET subject = $1, body = $2, trigger_event = $3, updated_at = NOW() WHERE id = $4",
      [params['subject'], params['body'], params['trigger_event'], params['id']]
    )
    puts "[ADMIN] Template de e-mail ID #{params['id']} foi atualizado."
    redirect '/admin/families'
  end

  get '/admin/licenses/export.csv' do
    protected!
    licenses = License.all_with_summary
    content_type 'text/csv'
    headers 'Content-Disposition' => "attachment; filename=\"licencas-smartmaniaa-#{Time.now.strftime('%Y%m%d')}.csv\""
    CSV.generate do |csv|
      csv << ["Email", "Chave de Licença", "Status Resumido", "Origens Ativas", "Data de Criação"]
      licenses.each do |license|
        csv << [
          license['email'], license['license_key'], license['summary_status'],
          license['summary_origins'], Time.parse(license['created_at']).strftime('%d/%m/%Y %H:%M')
        ]
      end
    end
  end

  # --- ROTAS DE GERENCIAMENTO DE ORIGENS ---

get '/admin/origins' do
  protected!
  @origins = $db.exec("SELECT * FROM manual_license_origins ORDER BY display_name")
  erb :admin_manage_origins
end

post '/admin/origins' do
  protected!
  key = params['origin_key'].downcase.strip
  display_name = params['display_name'].strip
  $db.exec_params("INSERT INTO manual_license_origins (origin_key, display_name) VALUES ($1, $2)", [key, display_name])
  redirect '/admin/origins'
end

post '/admin/origins/:id/delete' do
  protected!
  $db.exec_params("DELETE FROM manual_license_origins WHERE id = $1", [params['id']])
  redirect '/admin/origins'
end

  post '/webhook/sendgrid_events' do
    # Bloco de segurança que precisa ser reativado
    # unless ENV['SENDGRID_WEBHOOK_KEY'] ... end
    
    request_body = request.body.read
    
    # Bloco de verificação de assinatura que precisa ser reativado
    # begin ... rescue ... end

    begin
      events = JSON.parse(request_body)
    rescue JSON::ParserError
      halt 400, "Invalid JSON payload"
    end

    events.each do |event|
      event_type = event['event']
      email = event['email']
      
      license_info = $db.exec_params("SELECT family FROM licenses WHERE lower(email) = lower($1) LIMIT 1", [email]).first
      family_name = license_info ? license_info['family'] : 'geral'

      case event_type
      when 'bounce', 'dropped'
        reason = event['reason'] || "Não especificado"
        status_code = event['status'] || "N/A"
        bounce_type = event['type'] || "N/A"
        error_details_text = "Motivo: #{reason} (Status: #{status_code}, Tipo de Bounce: #{bounce_type})"
        
        puts "[SENDGRID] Entrega FALHOU para '#{email}'. #{error_details_text}"
        $db.exec_params("UPDATE licenses SET email_status = 'bounced' WHERE lower(email) = lower($1)", [email])
        
        # --- CORREÇÃO APLICADA AQUI ---
        SmartManiaaApp.log_event(level: 'error', source: 'sendgrid_webhook', message: "Falha permanente na entrega para o e-mail: #{email}", details: event)
        
        Mailer.send_admin_notification(
          subject: "‼️ Falha na Entrega de E-mail para #{email}",
          body: "O envio de e-mail para <strong>#{email}</strong> falhou permanentemente.<br><br><strong>Detalhes do Erro:</strong><br>#{error_details_text}",
          family: family_name
        )

      when 'spamreport'
        puts "[SENDGRID] ALERTA DE SPAM para '#{email}'."
        $db.exec_params("UPDATE licenses SET email_status = 'spam_report' WHERE lower(email) = lower($1)", [email])
        
        # --- CORREÇÃO APLICADA AQUI ---
        SmartManiaaApp.log_event(level: 'warning', source: 'sendgrid_webhook', message: "Usuário #{email} marcou e-mail como SPAM.", details: event)
        Mailer.send_admin_notification(
          subject: "⚠️ Alerta de SPAM para #{email}",
          body: "O usuário com o e-mail <strong>#{email}</strong> marcou um de nossos e-mails como SPAM. A reputação de envio pode ser afetada.",
          family: family_name
        )
        
      when 'delivered'
        puts "[SENDGRID] E-mail para '#{email}' entregue com sucesso."
        $db.exec_params("UPDATE licenses SET email_status = 'ok' WHERE lower(email) = lower($1) AND email_status != 'ok'", [email])
      
      else
        puts "[SENDGRID] Evento não mapeado recebido: #{event_type} para o e-mail #{email}"
        # --- CORREÇÃO APLICADA AQUI ---
        SmartManiaaApp.log_event(level: 'info', source: 'sendgrid_webhook', message: "Recebido evento não mapeado: #{event_type}", details: event)
      end
    end

    status 200
    body 'Events received'
  end

  # --- Bloco final de inicialização ---
  port = ENV.fetch('PORT', 9292)
  SmartManiaaApp.run! host: '0.0.0.0', port: port if __FILE__ == $0

end # FIM DA CLASSE SmartManiaaApp