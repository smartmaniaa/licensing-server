require_relative 'server'

# ESSENCIAL: previne o erro 'Host not permitted' no Render/Sinatra
SmartManiaaApp.set :protection, false
SmartManiaaApp.set :bind, '0.0.0.0'

run SmartManiaaApp