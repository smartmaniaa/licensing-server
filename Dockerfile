FROM ruby:3.2

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

EXPOSE 10000

CMD ["bundle", "exec", "rackup", "-o", "0.0.0.0", "-p", "${PORT}", "config.ru"]
