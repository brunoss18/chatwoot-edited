module Whatsapp::IncomingMessageServiceHelpers
  # Quanto um evento espera pelo lock do contato antes de desistir. Valor do
  # fork de origem.
  CONTACT_LOCK_WAIT = 5.seconds

  def download_attachment_file(attachment_payload)
    Down.download(inbox.channel.media_url(attachment_payload[:id]), headers: inbox.channel.api_headers)
  end

  def conversation_params
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    }
  end

  def processed_params
    @processed_params ||= params
  end

  def account
    @account ||= inbox.account
  end

  def message_type
    messages_data.first[:type]
  end

  def message_content(message)
    return I18n.t('conversations.messages.whatsapp.flow_response') if message.dig(:interactive, :nfm_reply).present?

    # TODO: map interactive messages back to button messages in chatwoot
    message.dig(:text, :body) ||
      message.dig(:button, :text) ||
      message.dig(:interactive, :button_reply, :title) ||
      message.dig(:interactive, :list_reply, :title) ||
      message.dig(:name, :formatted_name)
  end

  def parse_flow_response_json(response_json)
    parsed_response = JSON.parse(response_json)
    parsed_response.is_a?(Hash) ? parsed_response : response_json
  rescue JSON::ParserError, TypeError
    response_json
  end

  def file_content_type(file_type)
    return :image if %w[image sticker].include?(file_type)
    return :audio if %w[audio voice].include?(file_type)
    return :video if ['video'].include?(file_type)
    return :location if ['location'].include?(file_type)
    return :contact if ['contacts'].include?(file_type)

    :file
  end

  def unprocessable_message_type?(message_type)
    %w[reaction ephemeral request_welcome].include?(message_type)
  end

  def processed_waid(waid)
    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(waid, :cloud)
  end

  def phone_number_candidates(phone_number)
    Whatsapp::PhoneNumberNormalizationService.new(inbox).phone_number_candidates(phone_number)
  end

  def whatsapp_phone_number(identifier)
    identifier = identifier.to_s
    return if identifier.blank?
    return unless identifier.match?(/\A\d{1,15}\z/)

    identifier
  end

  def error_webhook_event?(message)
    message.key?('errors')
  end

  def log_error(message)
    Rails.logger.warn "Whatsapp Error: #{message['errors'][0]['title']} - contact: #{message['from']}"
  end

  def process_in_reply_to(message)
    @in_reply_to_external_id = message['context']&.[]('id')
    return if @in_reply_to_external_id.blank?

    @in_reply_to_message_id = Whatsapp::InReplyToMessageFinder.new(
      conversation: @conversation,
      source_id: @in_reply_to_external_id
    ).perform&.id
  end

  def referral_attributes(message)
    return {} if outgoing_echo

    message[:referral]&.to_h&.deep_stringify_keys || {}
  end

  def find_message_by_source_id(source_id)
    return unless source_id

    @message = Message.find_by(source_id: source_id)
  end

  def lock_message_source_id!
    return false if messages_data.blank?

    Whatsapp::MessageDedupLock.new(messages_data.first[:id]).acquire!
  end

  # Serializa o tratamento de eventos do mesmo contato ou grupo. Os handlers do
  # Baileys chamam isto em oito pontos — mensagem individual, mensagem de grupo,
  # stub de grupo, atualizacao de participantes e de grupo. O port trouxe as
  # chamadas e nao a definicao, entao o primeiro evento de mensagem morria com
  # NoMethodError assim que o pareamento passava.
  #
  # Delega ao mesmo lock de chat que o resto do modulo usa, em vez de abrir uma
  # segunda familia de chaves no Redis: dois locks distintos para o mesmo chat
  # nao se enxergam, que e justamente a corrida que este guarda existe para
  # evitar.
  def with_contact_lock(phone, wait: CONTACT_LOCK_WAIT, &)
    raise ArgumentError, 'A block is required for with_contact_lock' unless block_given?
    return yield if phone.blank?

    Whatsapp::Session::Inbound::Locks.with_chat_lock(inbox, phone, wait: wait, &)
  end
end
