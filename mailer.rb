# ---- mailer.rb (Versão Final compatível com subject/body e legado) ----
require 'sendgrid-ruby'

module Mailer
  include SendGrid

  FROM_EMAIL = 'licensing@maniaa.com.br'
  ADMIN_EMAIL = 'smartmaniaa@maniaa.com.br'
  SENDGRID_API_KEY = ENV['SENDGRIDAPIKEY']

  # Patch: aceita subject/body OU license_key/type (para legado)
  def self.send_license_email(to_email:, subject: nil, body: nil, license_key: nil, type: nil)
    if subject && body
      # MODO NOVO: subject/body prontos
      html_content = body
      send_email(to: to_email, subject: subject, content: html_content)
    elsif license_key && type
      # MODO ANTIGO (compatibilidade)
      subject = if type == :trial
                  "Your SmartManiaa Trial Key!"
                else
                  "Your SmartManiaa License Has Been Activated!"
                end

      html_content = <<-HTML
        <h1>Thank you for using SmartManiaa plugins!</h1>
        <p>Hello,</p>
        <p>Your license key is ready to use. Please copy and paste the key below into your plugin to activate it.</p>
        <p><strong>Your Key:</strong></p>
        <p style="font-size: 20px; font-weight: bold; background-color: #f0f0f0; padding: 10px; border-radius: 5px; font-family: monospace;">
          #{license_key}
        </p>
        <p>If you have any questions, please feel free to contact us.</p>
        <p>Best regards,<br>The SmartManiaa Team</p>
      HTML

      send_email(to: to_email, subject: subject, content: html_content)
    else
      raise ArgumentError, "Missing expected parameters! Provide either subject+body OR license_key+type."
    end
  end

  # Mantém os métodos de upsell, trial denied e admin do jeito que já estavam
  def self.send_trial_denied_email(to_email:, solo_link:, suite_link:)
    subject = "Your SmartManiaa Plugin Trial Information"

    html_content = <<-HTML
      <h1>Hello from SmartManiaa!</h1>
      <p>We noticed you recently tried to start a trial for one of our plugins.</p>
      <p>It appears this email address or computer has already been used for a trial period. To continue, please choose one of the options below:</p>

      <table width="100%" border="0" cellspacing="0" cellpadding="0" style="text-align: center;">
        <tr>
          <td style="padding: 10px;">
            <a href="#{solo_link}" style="background-color: #007bff; color: white; padding: 12px 25px; text-decoration: none; border-radius: 5px; font-size: 16px; display: inline-block;">Purchase SmartGrid Axis</a>
          </td>
        </tr>
        <tr>
          <td style="padding: 10px;">
            <p style="margin: 0; font-size: 14px; color: #666;">or get the best value:</p>
          </td>
        </tr>
        <tr>
          <td style="padding: 10px;">
            <a href="#{suite_link}" style="background-color: #28a745; color: white; padding: 12px 25px; text-decoration: none; border-radius: 5px; font-size: 16px; display: inline-block;">Purchase the Full Suite</a>
          </td>
        </tr>
      </table>

      <p>Thank you for your interest!</p>
      <p>Best regards,<br>The SmartManiaa Team</p>
    HTML

    send_email(to: to_email, subject: subject, content: html_content)
  end

  def self.send_addon_upsell_email(to_email:, addon_link:, suite_link:, product_name:)
    subject = "Activate your SmartManiaa Add-on"

    html_content = <<-HTML
      <h1>Hello from SmartManiaa!</h1>
      <p>We noticed you tried to activate the <strong>#{product_name}</strong> add-on.</p>
      <p>To use this add-on, you need to purchase a license for it. Please choose one of the options below:</p>

      <table width="100%" border="0" cellspacing="0" cellpadding="0" style="text-align: center;">
        <tr>
          <td style="padding: 10px;">
            <a href="#{addon_link}" style="background-color: #007bff; color: white; padding: 12px 25px; text-decoration: none; border-radius: 5px; font-size: 16px; display: inline-block;">Purchase the #{product_name} Add-on</a>
          </td>
        </tr>
        <tr>
          <td style="padding: 10px;">
            <p style="margin: 0; font-size: 14px; color: #666;">or get the best value and unlock all add-ons:</p>
          </td>
        </tr>
        <tr>
          <td style="padding: 10px;">
            <a href="#{suite_link}" style="background-color: #28a745; color: white; padding: 12px 25px; text-decoration: none; border-radius: 5px; font-size: 16px; display: inline-block;">Upgrade to the Full Suite</a>
          </td>
        </tr>
      </table>

      <p>Thank you for being a customer!</p>
      <p>Best regards,<br>The SmartManiaa Team</p>
    HTML

    send_email(to: to_email, subject: subject, content: html_content)
  end

  def self.send_admin_notification(subject:, body:)
    html_content = "<h1>Notificação do Servidor de Licenças</h1><p>#{body}</p>"
    send_email(to: ADMIN_EMAIL, subject: subject, content: html_content)
  end

  private

  def self.send_email(to:, subject:, content:)
    from = Email.new(email: FROM_EMAIL)
    to = Email.new(email: to)
    content = Content.new(type: 'text/html', value: content)
    mail = Mail.new(from, subject, to, content)
    sg = SendGrid::API.new(api_key: SENDGRID_API_KEY)

    begin
      response = sg.client.mail._('send').post(request_body: mail.to_json)
      puts "=> E-mail para '#{to.email}' enviado para a fila do SendGrid. Status: #{response.status_code}"
    rescue Exception => e
      puts "=> ERRO AO ENVIAR E-MAIL: #{e.message}"
    end
  end
end
