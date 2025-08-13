# ---- Dockerfile ----

# Usar a imagem oficial do Ruby 3.3 como base
FROM ruby:3.3

# Instalar dependências essenciais do sistema operacional
RUN apt-get update -qq && apt-get install -y build-essential

# Definir o diretório de trabalho padrão dentro do container
WORKDIR /app

# Copiar o Gemfile para o container e instalar as gems
# Isso otimiza o cache, para não reinstalar tudo a cada pequena mudança no código
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Copiar o resto do código da nossa aplicação
COPY . .

# Expor a porta que o Puma usa para o mundo exterior
EXPOSE 9292

# O comando padrão para executar quando o container iniciar
CMD ["bundle", "exec", "puma"]