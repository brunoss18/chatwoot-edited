class Focoh::SupabaseTokenService
  pattr_initialize [:user!]

  # Namespace do UUIDv5 que deriva a identidade Supabase do usuário Chatwoot.
  # NUNCA alterar: mudar este valor troca o `sub` de todo mundo e desassocia o
  # histórico de autoria (laudos aprovados, fichas de risco lançadas).
  IDENTITY_NAMESPACE = 'b3f0c8a2-5d41-4a7e-9c6b-1f2e3d4c5b6a'.freeze

  # Token curto de propósito: ele é reemitido pelo board sob demanda, então uma
  # sessão revogada no Chatwoot para de valer em minutos, não em horas.
  EXPIRY_MINUTES = 15

  # Espelha `focoh_interno.papeis_focoh()` no Supabase. A duplicação é
  # deliberada: sem ela, um papel escrito errado na configuração viraria um
  # quadro vazio (a RLS não devolveria linha alguma) em vez de um erro visível.
  PAPEIS_CLINICOS = %w[
    recepcao
    gerente_familias
    medico_psiquiatra
    psicologo
    enfermeiro_rt
    coordenacao_tecnica
    diretor_geral
  ].freeze

  CUSTOM_ATTRIBUTE = 'focoh_clinical_role'.freeze

  class MissingClinicalRole < StandardError; end
  class InvalidClinicalRole < StandardError; end

  def generate_token
    JWT.encode(token_payload, secret_key, 'HS256')
  end

  def expires_at
    issued_at + EXPIRY_MINUTES.minutes
  end

  def clinical_role
    role = user.custom_attributes&.dig(CUSTOM_ATTRIBUTE)

    raise MissingClinicalRole if role.blank?
    raise InvalidClinicalRole unless PAPEIS_CLINICOS.include?(role)

    role
  end

  private

  def token_payload
    {
      sub: supabase_user_id,
      aud: 'authenticated',
      # `role` é o role do Postgres que a RLS assume. O papel clínico vai em
      # app_metadata, que é onde `focoh_interno.papel_atual()` o procura.
      role: 'authenticated',
      email: user.email,
      app_metadata: { provider: 'chatwoot', role: clinical_role },
      user_metadata: { name: user.name },
      iat: issued_at.to_i,
      exp: expires_at.to_i
    }
  end

  def supabase_user_id
    Digest::UUID.uuid_v5(IDENTITY_NAMESPACE, "chatwoot-user-#{user.id}")
  end

  def issued_at
    @issued_at ||= Time.zone.now
  end

  # Segredo JWT do projeto Supabase. Fica só no servidor: com ele é possível
  # forjar qualquer papel e a RLS deixa de isolar o escore de risco. Leitura
  # direta de propósito — ausência em produção é bug de deploy e deve estourar.
  def secret_key
    ENV.fetch('FOCOH_SUPABASE_JWT_SECRET')
  end
end
