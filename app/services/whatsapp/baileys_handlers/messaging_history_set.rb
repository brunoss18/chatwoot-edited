# WhatsApp's own account of what this inbox missed, and of what came before it existed.
#
# The phone sends this on its own after a pairing, and again after every reconnect, and it
# answers an explicit request with it. Baileys types the dump, which is the fact that makes
# this provider worth keeping alive for one more feature: `RECENT` is WhatsApp replaying
# what arrived while the device was offline, so a Baileys inbox can recover a disconnect
# that no other provider we serve can.
#
# The dump arrives in frames (see historySync.ts on the bridge), each one a slice of one
# `messaging-history.set` under the byte budget.
#
# IMPORTANTE, neste fork: a IMPORTAÇÃO do histórico não foi portada. O importador dependia
# do subsistema `Import::` (29 arquivos, uma feature de backfill via IMAP) e de
# `Whatsapp::Session::Inbound::ChatList`, nenhum dos dois presente aqui — e a referência
# pendurada impedia o eager load, ou seja, a aplicação não bootava em produção.
#
# O que sobrou deste handler é a contabilidade de exaustão: registrar que o WhatsApp disse
# que um chat não tem mais nada anterior, para a interface parar de oferecer "carregar mais".
# Mensagens novas seguem normais; o que não acontece é o histórico antigo ser importado no
# pareamento.
module Whatsapp::BaileysHandlers::MessagingHistorySet
  include Whatsapp::BaileysHandlers::Helpers

  # proto.HistorySync.HistorySyncType, as Baileys forwards it.
  INITIAL_BOOTSTRAP = 0
  INITIAL_STATUS_V3 = 1
  FULL = 2
  RECENT = 3
  PUSH_NAME = 4
  NON_BLOCKING_DATA = 5
  ON_DEMAND = 6

  # The four that carry conversation. The three that are left are the phone's status
  # updates, its address book display names and an app-state blob: none of them is a
  # message, and filing them would put empty rows in somebody's inbox.
  IMPORTABLE_SYNC_TYPES = [INITIAL_BOOTSTRAP, FULL, RECENT, ON_DEMAND].freeze

  private

  def process_messaging_history_set
    return unless inbox.channel.session_capabilities.include?('history_sync')

    data = processed_params[:data]
    return unless importable_sync_type?(data[:syncType])

    # Only the exhaustion bookkeeping: the import half of this handler is not part of this
    # fork. See the note at the top of the module.
    mark_exhausted(data)
  end

  # WhatsApp saying a chat has nothing older left, which it says on the answer to a
  # request and nowhere else -- the chat records in a volunteered dump never carry it.
  # Recorded on the thread so the control that sent the request can stop offering and say
  # what WhatsApp Web says in the same place: that the rest lives on the phone.
  #
  # Filed against the contact rather than one thread, because the anchor a request walks
  # back from is the oldest message the inbox holds for that chat across every thread it
  # opened. The answer is about the chat; which thread the operator happened to be reading
  # when they asked is not part of it.
  def mark_exhausted(data)
    Array(data[:exhausted]).each do |jid|
      conversations_for_chat(jid).each { |conversation| flag_exhausted(conversation) }
    end
  end

  # Matched on the id alone, without the domain: the answer is addressed the way WhatsApp
  # holds the chat, which is not always the way the request was addressed -- a request sent
  # to a LID comes back answered as `<phone>@s.whatsapp.net`. The id either side of that
  # swap is the one the contact inbox was keyed by.
  def conversations_for_chat(jid)
    source_id = jid.to_s.split('@').first
    return Conversation.none if source_id.blank?

    contact_inbox = inbox.contact_inboxes.find_by(source_id: source_id)
    return Conversation.none if contact_inbox.blank?

    inbox.conversations.where(contact_id: contact_inbox.contact_id)
  end

  def flag_exhausted(conversation)
    return if conversation.additional_attributes['history_exhausted']

    conversation.update!(additional_attributes: conversation.additional_attributes.merge('history_exhausted' => true))
  end

  # An absent type is taken as importable: the bridge may predate the field, and Coverage
  # decides what happens to the pile either way. Only a type we recognise as carrying no
  # conversation is dropped.
  def importable_sync_type?(sync_type)
    return true if sync_type.nil?

    IMPORTABLE_SYNC_TYPES.include?(sync_type.to_i)
  end
end
