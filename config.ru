require 'sinatra/base'

class TestApp < Sinatra::Base
  set :protection, false
  set :bind, '0.0.0.0'

  get('/') { 'HELLO WORLD' }
end

run TestApp
