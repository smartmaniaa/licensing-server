# ---- daily_tasks.rb (VERSÃO FINAL com verificação de atividade) ----
# Este script é executado diariamente por um Cron Job para disparar e-mails baseados em tempo.

require 'pg'
require 'dotenv/load'
require 'time'

require_relative 'models/license.rb'
require_relative 'mailer.rb'

class DailyTaskManager
  def initialize
    puts "[CRON] Iniciando Tarefas Diárias de E-mail..."
    connect_to_db
  end

  def connect_to_db
    # ... (código de conexão - sem alterações) ...
  end

  def run
    puts "[CRON] Executando verificações de e-mails agendados..."
    check_trials_ending_soon('trial_ending_in_3_days', 3)
    check_trials_expiring_today('trial_expires_today')
    check_expired_trials('trial_expired_3_days_ago', 3)
    check_expired_trials('trial_expired_7_days_ago', 7)
    check_post_cancellation_followups('subscription_revoked_7_days_ago', 7)
    check_post_cancellation_followups('subscription_revoked_30_days_ago', 30)
    puts "[CRON] Tarefas Diárias finalizadas."
  end

  private

  #-- NOVA FUNÇÃO DE VERIFICAÇÃO: Checa se o cliente já tem uma licença ativa na família.
  def is_customer_active_in_family?(license_id)
    active_check = $db.exec_params(
      "SELECT 1 FROM license_entitlements WHERE license_id = $1 AND status = 'active' LIMIT 1",
      [license_id]
    )
    return active_check.num_tuples > 0
  end

  def find_and_trigger(query, trigger_event, check_active: false)
    results = $db.exec(query)
    puts "[CRON] Gatilho '#{trigger_event}': #{results.num_tuples} candidato(s) encontrado(s)."
    
    triggered_count = 0
    results.each do |item|
      #-- Se for um e-mail de follow-up, primeiro verificamos se o cliente já não está ativo.
      if check_active && is_customer_active_in_family?(item['license_id'])
        puts "[CRON] -> Pulando e-mail para '#{item['email']}' (cliente já está ativo na família)."
        next # Pula para o próximo
      end

      License.send(:trigger_customer_email,
        trigger_event: trigger_event,
        family: item['family'],
        to_email: item['email'],
        license_key: item['license_key'],
        trial_end_date: item['trial_expires_at'] ? Time.parse(item['trial_expires_at']).strftime('%d/%m/%Y') : ''
      )
      triggered_count += 1
    end
    puts "[CRON] -> #{triggered_count} e-mail(s) foram efetivamente disparados."
  end

  #-- Gatilhos de "antes de vencer" não precisam da verificação de atividade.
  def check_trials_ending_soon(trigger, days)
    # ... (código deste método - sem alterações) ...
  end
  
  def check_trials_expiring_today(trigger)
    # ... (código deste método - sem alterações) ...
  end

  #-- Gatilhos de "depois de vencer" AGORA USAM a verificação de atividade.
  def check_expired_trials(trigger, days)
    query = %{
      SELECT l.id AS license_id, l.email, l.family, l.license_key FROM license_entitlements le
      JOIN licenses l ON le.license_id = l.id
      WHERE le.status = 'trial' AND le.trial_expires_at 
      BETWEEN NOW() - interval '#{days + 1} days' AND NOW() - interval '#{days} days'
    }
    find_and_trigger(query, trigger, check_active: true)
  end

  def check_post_cancellation_followups(trigger, days)
    query = %{
      SELECT l.id AS license_id, l.email, l.family, l.license_key FROM license_entitlements le
      JOIN licenses l ON le.license_id = l.id
      WHERE le.status = 'revoked' AND le.expires_at 
      BETWEEN NOW() - interval '#{days + 1} days' AND NOW() - interval '#{days} days'
    }
    find_and_trigger(query, trigger, check_active: true)
  end
end

if __FILE__ == $0
  DailyTaskManager.new.run
end