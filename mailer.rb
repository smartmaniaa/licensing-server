# ---- mailer.rb (VERSÃO FINAL, COMPLETA E CORRIGIDA - 23/08/2025) ----
require 'sendgrid-ruby'

module Mailer
  include SendGrid

  FROM_EMAIL = 'licensing@maniaa.com.br'
  # ADMIN_EMAIL não é mais usado para envio, mas pode ser mantido para outras finalidades.
  ADMIN_EMAIL = 'smartmaniaa@maniaa.com.br' 
  SENDGRID_API_KEY = ENV['SENDGRIDAPIKEY']
 
  # Arquivo: mailer.rb

  # E-mail enviado ao cliente (versão final corrigida)
  def self.send_license_email(to_email:, subject: nil, body: nil, license_key: nil, family: nil, sender_name: nil)
    # Cenário 1: E-mail customizado vindo do Centro de Controle (com subject e body)
    if subject && body
      send_email(to: to_email, subject: subject, content: body, sender_name: sender_name)

    # Cenário 2: E-mail padrão de envio de chave (apenas com license_key e family)
    elsif license_key && family
      subject = "Your SmartManiaa Key!"
      html_content = <<-HTML
        <h1>Your SmartManiaa Key for the '#{family.capitalize}' product family is ready!</h1>
        <p>Hello,</p>
        <p>Please keep this key safe. It is your unique identifier for all products in the <strong>#{family.capitalize}</strong> family that you currently own or may acquire in the future.</p>
        <p><strong>How it works:</strong> You will use this same key to activate any product from this family. If you purchase a new plugin from the same family, you will not receive a new key; instead, a new "entitlement" will be automatically added to this existing key.</p>
        <p><strong>Your Unique Key:</strong></p>
        <p style="font-size: 20px; font-weight: bold; background-color: #f0f0f0; padding: 10px; border-radius: 5px; font-family: monospace;">
          #{license_key}
        </p>
        <p>If you have any questions, please feel free to contact us.</p>
        <p>Best regards,<br>The SmartManiaa Team</p>
      HTML
      # CORREÇÃO: A chamada para o e-mail padrão agora também passa o sender_name (que será nil, e o método privado usará o padrão)
      send_email(to: to_email, subject: subject, content: html_content, sender_name: sender_name)
    else
      raise ArgumentError, "Parâmetros insuficientes para send_license_email!"
    end
  end

  private

  # Método privado que de fato envia o e-mail (versão final corrigida)
  def self.send_email(to:, subject:, content:, sender_name: nil)
    # Define um nome padrão se 'sender_name' for nulo ou vazio.
    from_name = sender_name && !sender_name.empty? ? sender_name : "SmartManiaa Team"
    
    from = Email.new(email: FROM_EMAIL, name: from_name)
    to = Email.new(email: to)
    content = Content.new(type: 'text/html', value: content)
    mail = Mail.new(from, subject, to, content)
    sg = SendGrid::API.new(api_key: SENDGRID_API_KEY)

    begin
      response = sg.client.mail._('send').post(request_body: mail.to_json)
      puts "[EMAIL] E-mail para '#{to.email}' (Remetente: '#{from_name}', Assunto: '#{subject}') enviado. Status: #{response.status_code}"
    rescue Exception => e
      puts "[EMAIL] ERRO ao enviar para '#{to.email}': #{e.message}"
    end
  end

  #-- MÉTODO ATUALIZADO: Agora envia notificações para admins de uma família específica.
  def self.send_admin_notification(subject:, body:, family:)
    # Busca todos os e-mails de notificadores para a família informada.
    notifiers = $db.exec_params("SELECT email FROM admin_notifiers WHERE family_name = $1", [family])
    
    return if notifiers.num_tuples.zero? # Se não houver ninguém, não faz nada.

    puts "[EMAIL] Enviando notificação de admin para a família '#{family}'..."
    notifiers.each do |notifier|
      html_content = "<h1>Notificação do Servidor de Licenças</h1><p>#{body}</p>"
      send_email(to: notifier['email'], subject: subject, content: html_content)
    end
  end

  private

  # Método privado agora aceita o parâmetro opcional 'sender_name'
  def self.send_email(to:, subject:, content:, sender_name: nil)
    # Define um nome padrão se 'sender_name' for nulo ou vazio.
    from_name = sender_name && !sender_name.empty? ? sender_name : "SmartManiaa Team"
    
    # Usa o 'from_name' ao criar o objeto de remetente.
    from = Email.new(email: FROM_EMAIL, name: from_name)
    to = Email.new(email: to)
    content = Content.new(type: 'text/html', value: content)
    mail = Mail.new(from, subject, to, content)
    sg = SendGrid::API.new(api_key: SENDGRID_API_KEY)

    begin
      response = sg.client.mail._('send').post(request_body: mail.to_json)
      # Log atualizado para incluir o nome do remetente
      puts "[EMAIL] E-mail para '#{to.email}' (Remetente: '#{from_name}', Assunto: '#{subject}') enviado. Status: #{response.status_code}"
    rescue Exception => e
      puts "[EMAIL] ERRO ao enviar para '#{to.email}': #{e.message}"
    end
  end

  # --- NOVO MÉTODO PARA CONFIRMAR A DESVINCULAÇÃO ---
  def self.send_unlink_confirmation_email(to_email:, token:, family:, server_base_url:)
    # O server_base_url é necessário para construir o link completo
    # Ex: https://licensing-server-1.onrender.com
    confirmation_link = "#{server_base_url}/confirm_unlink/#{token}"

    subject = "Confirmação de Desvinculação de Licença"
    html_content = <<-HTML
      <h1>Confirme sua Solicitação</h1>
      <p>Olá,</p>
      <p>Recebemos uma solicitação para desvincular sua licença da família de produtos '#{family.capitalize}' de um computador.</p>
      <p>Para confirmar esta ação e liberar sua chave para ser usada em uma nova máquina, por favor, clique no link abaixo. Este link é válido por 24 horas.</p>
      <p style="text-align: center; margin: 20px 0;">
        <a href="#{confirmation_link}" style="background-color: #0078d4; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px;">Confirmar Desvinculação</a>
      </p>
      <p>Se você não solicitou isso, pode ignorar este e-mail com segurança. Nenhuma ação será tomada.</p>
      <p>Atenciosamente,<br>Equipe SmartManiaa</p>
    HTML

    send_email(to: to_email, subject: subject, content: html_content)
  end

end