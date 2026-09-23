# Handles Brazil phone number normalization
# ref: https://github.com/chatwoot/chatwoot/issues/5840
# ref: https://www.gov.br/anatel/pt-br/regulado/numeracao/perguntas-frequentes
#
# Brazil changed its mobile number system by adding a "9" prefix to existing numbers.
# This normalizer adds the "9" only to legacy eight-digit mobile ranges, leaving
# eight-digit landlines (which start with 2-5) unchanged.
class Whatsapp::PhoneNormalizers::BrazilPhoneNormalizer < Whatsapp::PhoneNormalizers::BasePhoneNormalizer
  COUNTRY_CODE_LENGTH = 2
  DDD_LENGTH = 2
  LEGACY_MOBILE_NUMBER_PATTERN = /\A[6-9]\d{7}\z/

  def normalize(waid)
    return waid unless handles_country?(waid)

    ddd = waid[COUNTRY_CODE_LENGTH, DDD_LENGTH]
    number = waid[(COUNTRY_CODE_LENGTH + DDD_LENGTH)..].to_s
    return waid unless number.match?(LEGACY_MOBILE_NUMBER_PATTERN)

    "55#{ddd}9#{number}"
  end

  def contact_candidates(waid)
    [waid, normalize(waid)].uniq
  end

  # Os dois sentidos: acrescenta o 9 a um numero de 8 digitos e retira de um de
  # 9. `normalize` so faz o primeiro, entao um numero ja com 9 nao encontraria
  # o contato salvo na forma antiga.
  def variants(waid)
    return [waid] unless handles_country?(waid)

    ddd = waid[COUNTRY_CODE_LENGTH, DDD_LENGTH]
    number = waid[(COUNTRY_CODE_LENGTH + DDD_LENGTH)..].to_s

    candidates = [waid]
    candidates << "55#{ddd}9#{number}" if number.length == 8
    candidates << "55#{ddd}#{number[1..]}" if number.length == 9 && number.start_with?('9')
    candidates.uniq
  end

  private

  def country_code_pattern
    /^55/
  end
end
