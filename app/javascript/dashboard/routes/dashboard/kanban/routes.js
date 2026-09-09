import { CONVERSATION_PERMISSIONS, ROLES } from 'dashboard/constants/permissions';
import { frontendURL } from '../../../helper/URLHelper';
import KanbanIndex from './pages/KanbanIndex.vue';

/**
 * Kanban Clínico Rede Focoh.
 *
 * `meta.permissions` é o único lugar onde o RBAC do Chatwoot é declarado: a
 * sidebar lê daqui (via `resolvePermissions` do provider) para decidir se
 * mostra o item de menu. Recepção e atendimento entram como agentes.
 *
 * O papel clínico é uma camada separada e independente: quem pode ver escore
 * de risco ou aprovar laudo é decidido pela RLS do Supabase a partir de
 * `app_metadata.role`, nunca por este arquivo.
 */
export const routes = [
  {
    path: frontendURL('accounts/:accountId/kanban'),
    name: 'kanban_clinico_index',
    component: KanbanIndex,
    meta: {
      permissions: [...ROLES, ...CONVERSATION_PERMISSIONS],
    },
  },
];
