require 'dotenv/load'
require 'sinatra/base'
class ServerApp < Sinatra::Base
  get('/') { 'FUNCIONOU!' }
end