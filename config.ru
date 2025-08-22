require './hello'

HelloApp.set :protection, false
HelloApp.set :bind, '0.0.0.0'
HelloApp.set :port, ENV['PORT'] || 9292
HelloApp.set :environment, :production

# Libera todos os hosts externos — importante para Render.com
if HelloApp.respond_to?(:allow_hosts=)
  HelloApp.set :allow_hosts, nil
end

run HelloApp
