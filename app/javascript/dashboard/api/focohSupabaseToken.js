import ApiClient from './ApiClient';

class FocohSupabaseTokenAPI extends ApiClient {
  constructor() {
    super('focoh/supabase_token', { accountScoped: true });
  }

  // O token é emitido, não listado: o backend assina um JWT curto para o
  // usuário logado a cada chamada.
  issue() {
    return this.create();
  }
}

export default new FocohSupabaseTokenAPI();
