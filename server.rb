require 'sinatra/base'
require 'pg'
require 'json'
require 'dotenv/load'
require_relative 'models/license.rb'
require_relative 'models/product.rb'
require_relative 'mailer.rb'
require_relative 'stripe_config.rb'
require_relative 'stripe_handler.rb'
$stdout.sync = true

class SmartManiaaApp < Sinatra::Base
  # ======= AJUSTE ANTI-BLOQUEIO RENDER =======
  set :bind, '0.0.0.0'
  set :protection, false
  disable :protection
  # ===========================================

  before do
    puts "========= DEBUG HEADERS ========"
    puts "Host do request: #{request.host.inspect}"
    puts "Path: #{request.path_info}"
    puts "Headers: #{request.env.select { |k, _| k.start_with?('HTTP_') }}"
    puts "================================="
  end

  use Rack::MethodOverride
  enable :sessions
  set :session_secret, ENV.fetch("SESSION_SECRET", "c44e8293a0090265f725883a9c5ce960e58284695e84942a4981362a2b72f129")

  configure do
    retries = 5
    begin
      if ENV['DATABASE_URL'] # Render/cloud/local com URL pronta
        $db = PG.connect(ENV['DATABASE_URL'], sslmode: 'require')
        puts "=> Conectado ao banco de dados via DATABASE_URL (Render/cloud)!"
      else # Dev local simples, ex: Docker Compose
        $db = PG.connect(
          host: ENV.fetch('DATABASE_HOST', 'localhost'),
          dbname: ENV.fetch('DATABASE_NAME', 'smartmaniaa_licensing_dev'),
          user: ENV.fetch('DATABASE_USER', 'postgres'),
          password: ENV.fetch('DATABASE_PASSWORD', '@Rico5626')
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
  end

  # --- ROTAS PÚBLICAS ---
  get '/' do
    content_type :json
    puts "[LOG] Rota GET / foi acessada."
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
    family = License.find_family_by_sku(product_sku)
    family_skus = License.all_family_skus(family)
    expires_at = (Time.now + 7*24*60*60).strftime('%Y-%m-%d')

    if License.trial_exists?(email: email, mac_address: mac_address, family: family)
      License.log_trial_denied(
        email: email,
        mac_address: mac_address,
        product_sku: product_sku,
        reason: "Trial já existe para este email ou MAC na família #{family}"
      )
      halt 403, { error: "Trial já existe para este email ou MAC.", status: "denied" }.to_json
    end

    result = License.provision_license(
      email: email,
      family: family,
      product_skus: family_skus,
      origin: 'trial',
      status: 'trial',
      expires_at: expires_at,
      mac_address: mac_address,
      grant_source: "trial_#{family}"
    )
    result.to_json
  end

  post '/validate' do
    content_type :json
    begin
      params = JSON.parse(request.body.read)
    rescue JSON::ParserError
      halt 400, { error: 'Invalid JSON' }.to_json
    end

    validation_result = License.validate(
      key: params['license_key'],
      mac_address: params['mac_address'],
      product_sku: params['product_sku']
    )
    validation_result.to_json
  end

  # --- ROTAS DE TESTE ---
  get '/admin/create_suite_test' do
    content_type :json
    email_teste = "teste-#{Time.now.to_i}@smartmaniaa.com.br"
    produtos_da_suite_result = $db.exec("SELECT sku FROM products WHERE family = 'smartgrid'")
    produtos_da_suite = produtos_da_suite_result.map { |row| row['sku'] }
    family = License.find_family_by_sku(produtos_da_suite.first)
    License.provision_license(
      email: email_teste,
      family: family,
      product_skus: produtos_da_suite,
      origin: 'manual_test',
      status: 'active'
    )
    { message: "Chave de licença para a Suite completa gerada com sucesso" }.to_json
  end

  get '/test_stripe_webhook' do
    content_type :json
    begin
      payload = File.read('test_payload.json')
      StripeHandler.handle_webhook(payload, "dummy_signature_for_test")
      { status: 'ok', message: 'Simulação de webhook processada (sem verificação de assinatura).' }.to_json
    rescue Errno::ENOENT
      halt 500, { error: 'Arquivo test_payload.json não encontrado.' }.to_json
    rescue JSON::ParserError
      halt 500, { error: 'Conteúdo de test_payload.json não é um JSON válido.' }.to_json
    end
  end

  # --- ROTAS DO PAINEL DE ADMIN ---
  get '/admin' do
    protected!
    @licenses = License.filter(query: params['q'], origin: params['origin'])
    @origins = $db.exec('SELECT DISTINCT origin FROM licenses WHERE origin IS NOT NULL ORDER BY origin').map { |row| row['origin'] }
    erb :admin_dashboard
  end

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
      family: params['family']
    )
    if success
      Product.save_platform_product(
        sku: params['sku'],
        platform: 'stripe',
        platform_id: params['platform_id'],
        link: params['purchase_link']
      )
      $db.exec_params(
        "UPDATE products SET stripe_price_id = $1 WHERE sku = $2",
        [params['platform_id'], params['sku']]
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
    success = Product.update(
      sku: product_sku,
      name: params['name'],
      family: params['family']
    )
    if success
      Product.save_platform_product(
        sku: product_sku,
        platform: 'stripe',
        platform_id: params['platform_id'],
        link: params['purchase_link']
      )
      $db.exec_params(
        "UPDATE products SET stripe_price_id = $1 WHERE sku = $2",
        [params['platform_id'], product_sku]
      )
      component_skus = params['component_skus'] || []
      Product.update_suite_components(suite_sku: product_sku, component_skus: component_skus)
      redirect '/admin/products'
    else
      session[:error] = "Falha ao atualizar o produto. O Nome do Produto já existe."
      redirect "/admin/product/#{product_sku}/edit"
    end
  end

  post '/admin/product/:sku/delete' do
    protected!
    Product.delete(params['sku'])
    redirect '/admin/products'
  end

  get '/admin/new' do
    protected!
    @products = Product.all
    erb :admin_new_license
  end

  post '/admin/create' do
    protected!
    email = params['email']
    product_skus = params['product_skus']
    origin = params['origin']
    if product_skus.nil? || product_skus.empty?
      halt 400, "Erro: Você deve selecionar pelo menos um produto."
    end
    family = License.find_family_by_sku(product_skus.first)
    License.provision_license(
      email: email,
      family: family,
      product_skus: product_skus,
      origin: origin,
      status: 'active'
    )
    redirect '/admin'
  end

  get '/admin/license/:id' do
    protected!
    license_id = params['id']
    @license = License.find(license_id)
    @entitlements = License.find_entitlements(license_id)
    erb :license_detail
  end

  post '/admin/license/:id/revoke' do
    protected!
    license_id = params['id']
    License.revoke(license_id)
    redirect "/admin/license/#{license_id}"
  end

  post '/admin/license/:id/unlink_mac' do
    protected!
    license_id = params['id']
    License.unlink_mac(license_id)
    redirect "/admin/license/#{license_id}"
  end

  post '/admin/license/:id/delete' do
    protected!
    license_id = params['id']
    License.delete(license_id)
    redirect '/admin'
  end

  post '/admin/grant/:id/revoke' do
    protected!
    grant_id = params['id']
    license_id = params['license_id']
    License.revoke_grant(grant_id)
    redirect "/admin/license/#{license_id}"
  end

  post '/admin/trials/clear' do
    protected!
    $db.exec("TRUNCATE trial_attempts RESTART IDENTITY;")
    $db.exec("TRUNCATE trial_email_counters RESTART IDENTITY;")
    $db.exec("TRUNCATE trial_mac_counters RESTART IDENTITY;")
    session[:notice] = "Todos os registros de tentativas negadas foram apagados!"
    redirect '/admin/trials'
  end

  get '/admin/trials' do
    protected!
    @attempts = License.all_trial_attempts
    @top_email_counters = $db.exec("SELECT * FROM trial_email_counters ORDER BY attempts DESC, last_attempt_at DESC LIMIT 20")
    @top_mac_counters = $db.exec("SELECT * FROM trial_mac_counters ORDER BY attempts DESC, last_attempt_at DESC LIMIT 20")
    erb :admin_trial_attempts
  end

  get '/admin/duplicates' do
    protected!
    @duplicates = License.find_duplicate_subscriptions
    erb :admin_duplicate_subscriptions
  end

  get '/admin/emails' do
    @email_rules = $db.exec("SELECT * FROM email_rules ORDER BY updated_at DESC, id DESC").to_a
    erb :admin_mail_rules
  end

  get '/admin/emails/new' do
    @editing = false
    @rule = nil
    @email_types = $db.exec("SELECT * FROM email_types ORDER BY name ASC").to_a
    @families = $db.exec("SELECT DISTINCT name FROM families ORDER BY name ASC").map { |f| f['name'] }
    erb :admin_mail_rule_form
  end

  get '/admin/emails/:id/edit' do
    id = params[:id]
    @editing = true
    @rule = $db.exec_params("SELECT * FROM email_rules WHERE id = $1 LIMIT 1", [id]).first
    @email_types = $db.exec("SELECT * FROM email_types ORDER BY name ASC").to_a
    @families = $db.exec("SELECT DISTINCT name FROM families ORDER BY name ASC").map { |f| f['name'] }
    erb :admin_mail_rule_form
  end

  # server.rb
  post '/stripe/webhook' do
    payload = request.body.read
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    # Fluxo principal usando o handler
    status, headers, body = StripeHandler.handle_webhook(payload, sig_header)
    # Sinatra espera a resposta assim:
    status status
    headers.each { |k, v| response[k] = v }
    body body.join
  end
end

# --- Inicialização padrão para dev/local/Render ---
port = ENV.fetch('PORT', 9292)
SmartManiaaApp.run! host: '0.0.0.0', port: port if __FILE__ == $0
