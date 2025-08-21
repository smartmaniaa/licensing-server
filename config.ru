require_relative 'server'

# Garante que não vai bloquear nenhum host
SmartManiaaApp.set :protection, false
SmartManiaaApp.set :bind, '0.0.0.0'
SmartManiaaApp.set :port, ENV['PORT'] # ---> ESSENCIAL, ajuste mais importante!

run SmartManiaaApp