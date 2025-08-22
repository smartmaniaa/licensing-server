FROM ruby:3.2

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

EXPOSE 9292

CMD ["bundle", "exec", "rackup", "-o", "0.0.0.0", "-p", "9292", "config.ru"]
