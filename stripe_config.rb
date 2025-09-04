# ---- stripe_config.rb (Arquivo Novo) ----
require 'stripe'

# Define a chave secreta da API para toda a aplicação.
# Trate esta chave como uma senha!
Stripe.api_key = ENV['STRIPE_API_KEY']