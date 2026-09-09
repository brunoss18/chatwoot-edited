class Api::V1::Accounts::Focoh::SupabaseTokensController < Api::V1::Accounts::BaseController
  # Emite um JWT Supabase de curta duração para o usuário logado, com o papel
  # clínico em `app_metadata.role`. É a ponte entre a sessão do Chatwoot e a RLS
  # do Supabase: o segredo de assinatura nunca sai do servidor.
  #
  # `::Focoh::` com escopo explícito porque este controller vive dentro de um
  # namespace `Focoh` — sem o prefixo a resolução de constante fica ambígua.
  def create
    service = ::Focoh::SupabaseTokenService.new(user: Current.user)

    render json: {
      access_token: service.generate_token,
      expires_at: service.expires_at.to_i
    }
  rescue ::Focoh::SupabaseTokenService::MissingClinicalRole
    render json: { error: 'clinical_role_missing' }, status: :forbidden
  rescue ::Focoh::SupabaseTokenService::InvalidClinicalRole
    render json: { error: 'clinical_role_invalid' }, status: :forbidden
  end
end
