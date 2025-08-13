require 'net/http'
require 'json'
require 'socket'
require 'open3'

def get_mac_address
  if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
    output = `getmac`.force_encoding("CP850").encode("UTF-8")
    output[/([A-F0-9]{2}[:-]){5}[A-F0-9]{2}/i]
  elsif RbConfig::CONFIG['host_os'] =~ /darwin|linux/
    # Pega o primeiro MAC válido
    mac = nil
    Open3.popen3('ifconfig') do |stdin, stdout, stderr, wait_thr|
      stdout.each_line do |line|
        if line =~ /(?:ether|HWaddr)\s+([a-fA-F0-9:]{17})/
          mac = $1.strip.upcase
          break
        end
      end
    end
    mac
  else
    nil
  end
end

def simulate_trial(email, product_sku, server_url)
  mac_address = get_mac_address
  unless mac_address
    puts "Não foi possível obter o endereço MAC automaticamente."
    exit 1
  end

  uri = URI("#{server_url}/start_trial")
  headers = { 'Content-Type' => 'application/json' }
  body = {
    email: email,
    mac_address: mac_address,
    product_sku: product_sku
  }.to_json

  response = Net::HTTP.post(uri, body, headers)
  puts "Resposta da API:"
  puts JSON.pretty_generate(JSON.parse(response.body))
end

# ====== CONFIGURAÇÃO =======
# Altere conforme seu ambiente:
server_url = "http://localhost:9292" # ou o IP/porta do seu servidor
email = "leo_itape@hotmail.com"
product_sku = "smartgrid_axis" # Substitua pelo SKU verdadeiro cadastrado

simulate_trial(email, product_sku, server_url)
