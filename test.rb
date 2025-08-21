require 'sinatra/base'
class TestApp < Sinatra::Base
  get('/') { 'HELLO WORLD' }
end
