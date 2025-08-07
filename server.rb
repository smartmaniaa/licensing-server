# Importa a biblioteca do Sinatra
require 'sinatra'

# Define uma rota para a página inicial ("/")
# Quando alguém acessar a página inicial, o código dentro do "do...end" será executado.
get '/' do
  "Nosso Servidor Está no Ar!"
end