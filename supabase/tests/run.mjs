// ============================================================================
// Kanban Clínico Rede Focoh — harness de verificação das travas
// ----------------------------------------------------------------------------
// Roda as migrations + o seed num Postgres real embarcado (PGlite/WASM) e
// exercita cada trava clínica com o papel de quem faria a operação no board.
//
//   cd supabase/tests && npm install && npm test
//
// Não substitui `supabase db reset` contra o projeto real; serve para provar,
// sem Docker, que as travas rejeitam o que devem rejeitar. Cada cenário roda em
// transação própria com rollback, então a ordem não importa.
// ============================================================================

import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const AQUI = dirname(fileURLToPath(import.meta.url));
const DIR_MIGRATIONS = join(AQUI, '..', 'migrations');

const PACIENTES = {
  ana: '11111111-1111-4111-8111-111111111111',
  bruno: '22222222-2222-4222-8222-222222222222',
  carla: '33333333-3333-4333-8333-333333333333',
  diego: '44444444-4444-4444-8444-444444444444',
  elisa: '55555555-5555-4555-8555-555555555555',
  felipe: '66666666-6666-4666-8666-666666666666',
};

const MSG_AVANCO_BLOQUEADO =
  'Avanço Bloqueado: A transição de fase exige a aprovação dos 3 Laudos Semanais ' +
  '(Clínico, Terapêutico e Disciplinar) e a ausência de riscos ativos. ' +
  'Verifique as pendências com a Coordenação Técnica.';

const db = await PGlite.create();
const resultados = [];

const jwt = papel =>
  JSON.stringify({
    role: 'authenticated',
    sub: '99999999-9999-4999-8999-999999999999',
    app_metadata: { role: papel },
  });

// Executa `fn` como um usuário logado com o papel clínico informado, numa
// transação sempre desfeita no final. `fn` recebe `assumir`, para cenários que
// envolvem dois papéis (ex.: coordenação muda a config, médico lança a ficha).
const comoPapel = async (papel, fn) => {
  const assumir = async p => {
    await db.exec('reset role');
    await db.query('select set_config($1, $2, true)', ['request.jwt.claims', jwt(p)]);
    await db.exec('set local role authenticated');
  };

  await db.exec('begin');
  try {
    await assumir(papel);
    return await fn(assumir);
  } finally {
    await db.exec('rollback');
  }
};

const erroDe = e => ({
  code: e?.code ?? e?.cause?.code ?? null,
  message: (e?.message ?? String(e)).trim(),
  detail: e?.detail ?? e?.cause?.detail ?? null,
});

const registrar = (nome, esperado, obtido, ok) => {
  resultados.push({ nome, esperado, obtido, ok });
  const marca = ok ? 'PASS' : 'FAIL';
  console.log(`  [${marca}] ${nome}`);
  console.log(`         esperado: ${esperado}`);
  console.log(`         obtido:   ${obtido}`);
};

// Espera que a operação seja REJEITADA com o SQLSTATE informado.
const esperaBloqueio = async (nome, papel, { code, message }, operacao) => {
  await comoPapel(papel, async assumir => {
    try {
      await operacao(assumir);
      registrar(nome, `rejeição ${code}`, 'operação foi ACEITA', false);
    } catch (e) {
      const err = erroDe(e);
      const okCode = err.code === code;
      const okMsg = message === undefined || err.message === message;
      registrar(
        nome,
        `rejeição ${code}${message ? ' + texto oficial' : ''}`,
        `${err.code} | ${err.message}${err.detail ? ` | DETAIL: ${err.detail}` : ''}`,
        okCode && okMsg
      );
    }
  });
};

// Espera que a operação seja ACEITA e que `verificacao` confirme o efeito.
const esperaSucesso = async (nome, papel, esperado, operacao) => {
  await comoPapel(papel, async assumir => {
    try {
      const obtido = await operacao(assumir);
      registrar(nome, esperado, String(obtido), String(obtido) === esperado);
    } catch (e) {
      const err = erroDe(e);
      registrar(nome, esperado, `rejeitado: ${err.code} | ${err.message}`, false);
    }
  });
};

// --------------------------------------------------------------------------
// Setup
// --------------------------------------------------------------------------
// A migration de extensões instala pg_net e pg_cron, o que o Postgres em WASM
// não faz. Ela é a única pulada, e os stubs entram no lugar — ver o cabeçalho
// de 01_prelude_stubs_pg_net_pg_cron.sql para a fronteira do teste.
const MIGRATION_DE_EXTENSOES = 'focoh_kanban_extensions.sql';

console.log('\n== Aplicando prelúdio Supabase (roles, schema auth) ==');
await db.exec(await readFile(join(AQUI, '00_prelude_supabase_local.sql'), 'utf8'));
await db.exec(await readFile(join(AQUI, '01_prelude_stubs_pg_net_pg_cron.sql'), 'utf8'));

console.log('\n== Aplicando migrations ==');
const migrations = (await readdir(DIR_MIGRATIONS)).filter(f => f.endsWith('.sql')).sort();
for (const arquivo of migrations) {
  if (arquivo.endsWith(MIGRATION_DE_EXTENSOES)) {
    console.log(`  --  ${arquivo} (pulada: extensões nativas, stub carregado)`);
    continue;
  }
  await db.exec(await readFile(join(DIR_MIGRATIONS, arquivo), 'utf8'));
  console.log(`  ok  ${arquivo}`);
}

console.log('\n== Aplicando seed ==');
await db.exec(await readFile(join(AQUI, '..', 'seed.sql'), 'utf8'));
const { rows: censo } = await db.query(
  'select fase::text, count(*)::int as total from public.pacientes group by 1 order by 1'
);
console.log(`  ok  seed.sql — ${censo.map(r => `${r.fase}=${r.total}`).join(' ')}`);

// --------------------------------------------------------------------------
// Cenários exigidos: travas de avanço de fase
// --------------------------------------------------------------------------
console.log('\n== (a) Sem os 3 laudos -> avanço barrado ==');
await esperaBloqueio(
  'recepção move Ana (0 laudos, risco baixo) para Fase 1',
  'recepcao',
  { code: 'FCH01', message: MSG_AVANCO_BLOQUEADO },
  () =>
    db.query("update public.pacientes set fase = 'fase1_autocritica' where id = $1", [
      PACIENTES.ana,
    ])
);

console.log('\n== (b) 3 laudos + risco baixo -> avança ==');
await esperaSucesso(
  'recepção move Bruno (3 laudos, risco baixo) para Fase 1',
  'recepcao',
  'fase1_autocritica',
  async () => {
    await db.query("update public.pacientes set fase = 'fase1_autocritica' where id = $1", [
      PACIENTES.bruno,
    ]);
    const { rows } = await db.query('select fase::text from public.pacientes where id = $1', [
      PACIENTES.bruno,
    ]);
    return rows[0].fase;
  }
);

await esperaSucesso(
  'transição de Bruno foi registrada na auditoria',
  'coordenacao_tecnica',
  '1',
  async () => {
    await db.query("update public.pacientes set fase = 'fase1_autocritica' where id = $1", [
      PACIENTES.bruno,
    ]);
    const { rows } = await db.query(
      `select count(*)::text as total from public.auditoria_transicoes_fase
        where paciente_id = $1 and fase_destino = 'fase1_autocritica'`,
      [PACIENTES.bruno]
    );
    return rows[0].total;
  }
);

console.log('\n== (c) Risco moderado/alto -> barrado mesmo com os 3 laudos ==');
await esperaBloqueio(
  'recepção move Carla (3 laudos, escore 16 -> moderado) para Fase 1',
  'recepcao',
  { code: 'FCH01', message: MSG_AVANCO_BLOQUEADO },
  () =>
    db.query("update public.pacientes set fase = 'fase1_autocritica' where id = $1", [
      PACIENTES.carla,
    ])
);

console.log('\n== (d) Alta sem PDF assinado -> barrada ==');
await esperaBloqueio(
  'coordenação arquiva Diego (coluna 6, termo sem assinatura)',
  'coordenacao_tecnica',
  { code: 'FCH02' },
  () =>
    db.query('update public.pacientes set arquivado = true where id = $1', [PACIENTES.diego])
);

await esperaSucesso(
  'controle positivo: arquiva Elisa (termo assinado com PDF)',
  'coordenacao_tecnica',
  'arquivado_em preenchido',
  async () => {
    await db.query('update public.pacientes set arquivado = true where id = $1', [
      PACIENTES.elisa,
    ]);
    const { rows } = await db.query(
      'select arquivado, arquivado_em is not null as tem_data from public.pacientes where id = $1',
      [PACIENTES.elisa]
    );
    return rows[0].arquivado && rows[0].tem_data ? 'arquivado_em preenchido' : 'estado inesperado';
  }
);

// --------------------------------------------------------------------------
// Cenários adicionais das regras documentadas
// --------------------------------------------------------------------------
console.log('\n== Regras de coluna e integridade da jornada ==');
await esperaBloqueio(
  'visita agendada nos primeiros 30 dias (Felipe, admitido hoje)',
  'recepcao',
  { code: 'FCH03' },
  () =>
    db.query(
      `insert into public.agendamentos_visita (paciente_id, data_visita, visitante)
       values ($1, focoh_interno.hoje() + 1, '[TESTE] Familiar')`,
      [PACIENTES.felipe]
    )
);

await esperaSucesso(
  'visita agendada após 30 dias (Ana, admitida há 40 dias)',
  'recepcao',
  '1',
  async () => {
    const { rows } = await db.query(
      `insert into public.agendamentos_visita (paciente_id, data_visita, visitante)
       values ($1, focoh_interno.hoje() + 1, '[TESTE] Familiar') returning 1 as ok`,
      [PACIENTES.ana]
    );
    return rows[0].ok;
  }
);

await esperaBloqueio(
  'pular colunas: Bruno da Admissão direto para a Fase 3',
  'recepcao',
  { code: 'FCH06' },
  () =>
    db.query("update public.pacientes set fase = 'fase3_empatia' where id = $1", [PACIENTES.bruno])
);

await esperaBloqueio(
  'criar paciente já na Fase 4 (bypass da trava por INSERT)',
  'recepcao',
  { code: 'FCH07' },
  () =>
    db.exec(
      `insert into public.pacientes (nome, fase)
       values ('[TESTE] Bypass', 'fase4_identidade')`
    )
);

await esperaBloqueio(
  'recepção tenta regredir a fase de Bruno',
  'recepcao',
  { code: 'FCH05' },
  async () => {
    await db.query("update public.pacientes set fase = 'fase1_autocritica' where id = $1", [
      PACIENTES.bruno,
    ]);
    await db.query("update public.pacientes set fase = 'admissao_triagem' where id = $1", [
      PACIENTES.bruno,
    ]);
  }
);

// --------------------------------------------------------------------------
// Isolamento do escore de risco de suicídio
// --------------------------------------------------------------------------
console.log('\n== Isolamento do dado sensível (RLS) ==');
await esperaSucesso(
  'recepção lendo avaliacoes_risco vê 0 linhas',
  'recepcao',
  '0',
  async () => (await db.query('select count(*)::text as t from public.avaliacoes_risco')).rows[0].t
);

await esperaSucesso(
  'equipe clínica lendo avaliacoes_risco vê as 6 fichas',
  'medico_psiquiatra',
  '6',
  async () => (await db.query('select count(*)::text as t from public.avaliacoes_risco')).rows[0].t
);

await esperaSucesso(
  'recepção lendo laudos_semanais vê 0 linhas',
  'recepcao',
  '0',
  async () => (await db.query('select count(*)::text as t from public.laudos_semanais')).rows[0].t
);

await esperaSucesso(
  'cards_do_quadro() não expõe nenhuma coluna de escore/ideação',
  'recepcao',
  'sem colunas sensíveis',
  async () => {
    const { rows } = await db.query('select * from public.cards_do_quadro() limit 1');
    const proibidas = Object.keys(rows[0] ?? {}).filter(c =>
      /escore|ideacao|nivel_risco|avaliado/.test(c)
    );
    return proibidas.length === 0 ? 'sem colunas sensíveis' : `expôs: ${proibidas.join(', ')}`;
  }
);

await esperaSucesso(
  'cartão de Carla sinaliza Protocolo Vermelho ativo sem revelar gravidade',
  'recepcao',
  'protocolo_vermelho_ativo=true nivel_pendencia=pendencia_clinica',
  async () => {
    const { rows } = await db.query(
      'select protocolo_vermelho_ativo, nivel_pendencia::text as np from public.cards_do_quadro() where id = $1',
      [PACIENTES.carla]
    );
    return `protocolo_vermelho_ativo=${rows[0].protocolo_vermelho_ativo} nivel_pendencia=${rows[0].np}`;
  }
);

await esperaSucesso(
  'usuário autenticado sem papel Focoh não vê nenhum cartão',
  'sem_papel',
  '0',
  async () => (await db.query('select count(*)::text as t from public.cards_do_quadro()')).rows[0].t
);

// Regressão de um furo real, encontrado só ao aplicar num Supabase de verdade:
// os default privileges do Supabase concedem EXECUTE a `anon` em toda função
// nova de `public`, e `revoke ... from public` não desfaz concessão nominal.
// Um POST anônimo em /rest/v1/rpc/cards_do_quadro respondia 200.
await esperaSucesso(
  'anon NÃO pode executar cards_do_quadro (nem chamar, nem receber vazio)',
  'recepcao',
  'execute_anon=false',
  async () => {
    await db.exec('reset role');
    const { rows } = await db.query(
      "select has_function_privilege('anon', 'public.cards_do_quadro(boolean)', 'EXECUTE') as pode"
    );
    return `execute_anon=${rows[0].pode}`;
  }
);

await esperaSucesso(
  'anon NÃO pode executar nenhuma função de focoh_interno',
  'recepcao',
  'funcoes_expostas=0',
  async () => {
    await db.exec('reset role');
    const { rows } = await db.query(
      `select count(*)::text as t
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'focoh_interno'
          and has_function_privilege('anon', p.oid, 'EXECUTE')`
    );
    return `funcoes_expostas=${rows[0].t}`;
  }
);

// --------------------------------------------------------------------------
// Limiar do Protocolo Vermelho — configurável, não hard-coded
// --------------------------------------------------------------------------
console.log('\n== Limiar configurável do Protocolo Vermelho ==');
await esperaSucesso(
  'escore 14 (abaixo do limiar 15) classifica como baixo',
  'medico_psiquiatra',
  'baixo',
  async () => {
    const { rows } = await db.query(
      `insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 14)
       returning nivel::text as nivel`,
      [PACIENTES.ana]
    );
    return rows[0].nivel;
  }
);

await esperaSucesso(
  'escore 15 (no limiar) classifica como moderado',
  'medico_psiquiatra',
  'moderado',
  async () => {
    const { rows } = await db.query(
      `insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 15)
       returning nivel::text as nivel`,
      [PACIENTES.ana]
    );
    return rows[0].nivel;
  }
);

await esperaSucesso(
  'coordenação baixa o limiar para 10: escore 12 passa a ser moderado',
  'coordenacao_tecnica',
  'moderado',
  async assumir => {
    await db.query('update public.config_protocolo_vermelho set limiar_moderado = 10 where id = 1');
    await assumir('medico_psiquiatra');
    const { rows } = await db.query(
      `insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 12)
       returning nivel::text as nivel`,
      [PACIENTES.ana]
    );
    return rows[0].nivel;
  }
);

// A RLS nega por FILTRO, não por erro: o UPDATE da recepção casa com zero
// linhas e retorna sucesso com 0 afetadas. Vale registrar explicitamente,
// porque é o oposto das travas de fase (que gritam) e o frontend precisa saber
// que aqui não vem mensagem de erro alguma.
await esperaSucesso(
  'recepção tenta alterar o limiar: RLS filtra a linha, valor intacto',
  'recepcao',
  'afetadas=0 limiar=15',
  async assumir => {
    const res = await db.query(
      'update public.config_protocolo_vermelho set limiar_moderado = 20 where id = 1'
    );
    await assumir('coordenacao_tecnica');
    const { rows } = await db.query(
      'select limiar_moderado from public.config_protocolo_vermelho where id = 1'
    );
    return `afetadas=${res.affectedRows} limiar=${rows[0].limiar_moderado}`;
  }
);

await esperaSucesso(
  'config ainda NÃO validada clinicamente (trava de governança)',
  'coordenacao_tecnica',
  'validado_clinicamente=false',
  async () => {
    const { rows } = await db.query(
      'select validado_clinicamente from public.config_protocolo_vermelho where id = 1'
    );
    return `validado_clinicamente=${rows[0].validado_clinicamente}`;
  }
);

// --------------------------------------------------------------------------
// Board como a recepção o vê
// --------------------------------------------------------------------------
console.log('\n== Board como a recepção o vê (cards_do_quadro) ==');
await comoPapel('recepcao', async () => {
  const { rows } = await db.query('select * from public.cards_do_quadro()');
  console.table(
    rows.map(r => ({
      nome: r.nome.replace('[TESTE] ', ''),
      fase: r.fase,
      dias: r.dias_internado,
      tem_3_laudos: r.tem_3_laudos,
      pendentes: String(r.laudos_pendentes ?? '').replace(/[{}]/g, ''),
      pendencia: r.nivel_pendencia,
      protocolo_vermelho: r.protocolo_vermelho_ativo,
      pode_avancar: r.pode_avancar,
    }))
  );
});

// ==========================================================================
// GATILHO 1 — Copa (restrição alimentar)
// ==========================================================================
console.log('\n== Gatilho 1: Copa ==');
await esperaSucesso(
  '"Não possui" NÃO gera alerta para a copa',
  'enfermeiro_rt',
  '0',
  async assumir => {
    await db.query(
      `insert into public.fichas_admissao_enfermagem (paciente_id, restricao_alimentar, suite)
       values ($1, 'Não possui', 'Suíte 12')`,
      [PACIENTES.felipe]
    );
    await assumir('coordenacao_tecnica');
    return (
      await db.query(
        "select count(*)::text as t from public.webhooks_saida where evento = 'copa.restricao_alimentar'"
      )
    ).rows[0].t;
  }
);

await esperaSucesso(
  'restrição preenchida gera alerta com suíte e orientação',
  'enfermeiro_rt',
  'copa.restricao_alimentar | Suíte 12 | Alergia a frutos do mar',
  async assumir => {
    await db.query(
      `insert into public.fichas_admissao_enfermagem (paciente_id, restricao_alimentar, suite)
       values ($1, 'Alergia a frutos do mar', 'Suíte 12')`,
      [PACIENTES.felipe]
    );
    await assumir('coordenacao_tecnica');
    const { rows } = await db.query(
      `select evento::text as evento,
              payload ->> 'suite' as suite,
              payload ->> 'restricao_alimentar' as restricao
         from public.webhooks_saida
        where evento = 'copa.restricao_alimentar'`
    );
    return `${rows[0].evento} | ${rows[0].suite} | ${rows[0].restricao}`;
  }
);

await esperaSucesso(
  'payload da copa não carrega fase, escore nem dado clínico',
  'enfermeiro_rt',
  'sem dado clínico',
  async assumir => {
    await db.query(
      `insert into public.fichas_admissao_enfermagem (paciente_id, restricao_alimentar, suite)
       values ($1, 'Intolerância a lactose', 'Suíte 3')`,
      [PACIENTES.ana]
    );
    await assumir('coordenacao_tecnica');
    const { rows } = await db.query(
      "select payload from public.webhooks_saida where evento = 'copa.restricao_alimentar'"
    );
    const chaves = Object.keys(rows[0].payload);
    const proibidas = chaves.filter(c => /escore|ideacao|nivel|fase|laudo/.test(c));
    return proibidas.length === 0 ? 'sem dado clínico' : `expôs: ${proibidas.join(', ')}`;
  }
);

// ==========================================================================
// GATILHO 2 — PROTOCOLO VERMELHO
//
// Estes são os testes exigidos pela seção de segurança clínica: falham se o
// disparo não ocorrer no limiar, e falham se a falha de entrega não for
// auditada.
// ==========================================================================
console.log('\n== Gatilho 2: Protocolo Vermelho ==');

// Endpoint configurado, para exercitar o caminho de sucesso.
const configurarEndpointPV = () =>
  db.query(
    `update public.config_webhooks
        set url = 'https://exemplo.invalid/hooks/protocolo-vermelho'
      where evento = 'protocolo_vermelho.disparo'`
  );

await esperaSucesso(
  'ESCORE NO LIMIAR DISPARA: auditoria + outbox + UPCI ligada',
  'medico_psiquiatra',
  'disparos=1 webhooks=1 upci=true',
  async assumir => {
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 15)',
      [PACIENTES.bruno]
    );
    await assumir('coordenacao_tecnica');
    // Escopado por paciente: o seed já dispara o Protocolo Vermelho da Carla
    // (escore 16), então uma contagem global contaria o alerta dela também.
    const { rows: w } = await db.query(
      `select count(*)::text as t from public.webhooks_saida
        where evento = 'protocolo_vermelho.disparo' and paciente_id = $1`,
      [PACIENTES.bruno]
    );
    const { rows: p } = await db.query(
      'select upci_ativo from public.pacientes where id = $1',
      [PACIENTES.bruno]
    );
    await assumir('medico_psiquiatra');
    const { rows: d } = await db.query(
      'select count(*)::text as t from public.protocolo_vermelho_disparos where paciente_id = $1',
      [PACIENTES.bruno]
    );
    return `disparos=${d[0].t} webhooks=${w[0].t} upci=${p[0].upci_ativo}`;
  }
);

await esperaSucesso(
  'escore abaixo do limiar NÃO dispara',
  'medico_psiquiatra',
  'disparos=0',
  async () => {
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 14)',
      [PACIENTES.bruno]
    );
    const { rows } = await db.query(
      'select count(*)::text as t from public.protocolo_vermelho_disparos where paciente_id = $1',
      [PACIENTES.bruno]
    );
    return `disparos=${rows[0].t}`;
  }
);

await esperaSucesso(
  'PAYLOAD DO ALERTA NÃO CARREGA ESCORE, NÍVEL NEM IDEAÇÃO',
  'medico_psiquiatra',
  'sem dado sensível',
  async assumir => {
    await db.query(
      `insert into public.avaliacoes_risco (paciente_id, escore, ideacao_detalhes)
       values ($1, 19, 'texto sensível que não pode sair por WhatsApp')`,
      [PACIENTES.bruno]
    );
    await assumir('coordenacao_tecnica');
    const { rows } = await db.query(
      "select payload from public.webhooks_saida where evento = 'protocolo_vermelho.disparo'"
    );
    const serializado = JSON.stringify(rows[0].payload);
    const vazou = /escore|ideacao|sensível|moderado|alto/i.test(serializado);
    return vazou ? `vazou: ${serializado.slice(0, 120)}` : 'sem dado sensível';
  }
);

await esperaSucesso(
  'auditoria guarda o limiar que valia no momento do disparo',
  'coordenacao_tecnica',
  'limiar_aplicado=10',
  async assumir => {
    await db.query('update public.config_protocolo_vermelho set limiar_moderado = 10 where id = 1');
    await assumir('medico_psiquiatra');
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 12)',
      [PACIENTES.bruno]
    );
    const { rows } = await db.query(
      `select limiar_aplicado from public.protocolo_vermelho_disparos
        where paciente_id = $1 order by disparado_em desc limit 1`,
      [PACIENTES.bruno]
    );
    return `limiar_aplicado=${rows[0].limiar_aplicado}`;
  }
);

await esperaSucesso(
  'FALHA DE ENTREGA AUDITADA: endpoint não configurado aparece na view de alertas não entregues',
  'medico_psiquiatra',
  'estado=falhou erro=endpoint_nao_configurado nao_entregues=1',
  async assumir => {
    // config_webhooks.url nasce NULL: este é o estado de uma instalação nova.
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 18)',
      [PACIENTES.bruno]
    );
    const { rows: v } = await db.query(
      'select count(*)::text as t from public.protocolo_vermelho_alertas_nao_entregues where paciente_id = $1',
      [PACIENTES.bruno]
    );
    await assumir('coordenacao_tecnica');
    const { rows: s } = await db.query(
      `select estado::text as estado, ultimo_erro from public.webhooks_saida
        where evento = 'protocolo_vermelho.disparo' order by id desc limit 1`
    );
    return `estado=${s[0].estado} erro=${s[0].ultimo_erro} nao_entregues=${v[0].t}`;
  }
);

await esperaSucesso(
  'endpoint configurado: alerta sai e fica em trânsito com POST registrado',
  'diretor_geral',
  'estado=em_transito posts=1',
  async assumir => {
    await configurarEndpointPV();
    await assumir('medico_psiquiatra');
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 18)',
      [PACIENTES.bruno]
    );
    await assumir('coordenacao_tecnica');
    const { rows: s } = await db.query(
      `select estado::text as estado from public.webhooks_saida
        where evento = 'protocolo_vermelho.disparo' order by id desc limit 1`
    );
    // O stub do pg_net é introspecção do harness, não superfície da aplicação:
    // `authenticated` não tem (nem deve ter) USAGE no schema `net`.
    await db.exec('reset role');
    const { rows: n } = await db.query('select count(*)::text as t from net.requisicoes_stub');
    return `estado=${s[0].estado} posts=${n[0].t}`;
  }
);

await esperaSucesso(
  'reconciliação com HTTP 200 marca entrega comprovada e limpa a view',
  'diretor_geral',
  'estado=enviado nao_entregues=0',
  async assumir => {
    await configurarEndpointPV();
    await assumir('medico_psiquiatra');
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 18)',
      [PACIENTES.bruno]
    );
    await db.exec('reset role');
    const { rows: s } = await db.query(
      "select id, request_id from public.webhooks_saida where evento = 'protocolo_vermelho.disparo' order by id desc limit 1"
    );
    await db.query('insert into net._http_response (id, status_code) values ($1, 200)', [
      s[0].request_id,
    ]);
    await db.query('select focoh_interno.reconciliar_webhooks()');
    await assumir('medico_psiquiatra');
    const { rows: v } = await db.query(
      'select count(*)::text as t from public.protocolo_vermelho_alertas_nao_entregues where paciente_id = $1',
      [PACIENTES.bruno]
    );
    await assumir('coordenacao_tecnica');
    const { rows: f } = await db.query(
      'select estado::text as estado from public.webhooks_saida where id = $1',
      [s[0].id]
    );
    return `estado=${f[0].estado} nao_entregues=${v[0].t}`;
  }
);

await esperaSucesso(
  'reconciliação com HTTP 500 reenfileira para nova tentativa',
  'diretor_geral',
  'estado=pendente erro=http_status=500',
  async assumir => {
    await configurarEndpointPV();
    await assumir('medico_psiquiatra');
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 18)',
      [PACIENTES.bruno]
    );
    await db.exec('reset role');
    const { rows: s } = await db.query(
      "select id, request_id from public.webhooks_saida where evento = 'protocolo_vermelho.disparo' order by id desc limit 1"
    );
    await db.query('insert into net._http_response (id, status_code) values ($1, 500)', [
      s[0].request_id,
    ]);
    await db.query('select focoh_interno.reconciliar_webhooks()');
    const { rows: f } = await db.query(
      'select estado::text as estado, ultimo_erro from public.webhooks_saida where id = $1',
      [s[0].id]
    );
    return `estado=${f[0].estado} erro=${f[0].ultimo_erro}`;
  }
);

await esperaBloqueio(
  'recepção tenta encerrar a vigilância intensiva (UPCI)',
  'medico_psiquiatra',
  { code: 'FCH08' },
  async assumir => {
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 18)',
      [PACIENTES.bruno]
    );
    await assumir('recepcao');
    await db.query('update public.pacientes set upci_ativo = false where id = $1', [
      PACIENTES.bruno,
    ]);
  }
);

await esperaSucesso(
  'recepção vê o flag de UPCI no cartão, sem saber a gravidade',
  'medico_psiquiatra',
  'upci_ativo=true protocolo_vermelho_ativo=true',
  async assumir => {
    await db.query(
      'insert into public.avaliacoes_risco (paciente_id, escore) values ($1, 18)',
      [PACIENTES.bruno]
    );
    await assumir('recepcao');
    const { rows } = await db.query(
      'select upci_ativo, protocolo_vermelho_ativo from public.cards_do_quadro() where id = $1',
      [PACIENTES.bruno]
    );
    return `upci_ativo=${rows[0].upci_ativo} protocolo_vermelho_ativo=${rows[0].protocolo_vermelho_ativo}`;
  }
);

// ==========================================================================
// GATILHO 3 — cobrança cronometrada de laudos
// ==========================================================================
console.log('\n== Gatilho 3: cobrança de laudos ==');

// A janela depende do dia da semana configurado; o teste alinha a config ao
// hoje do harness para exercitar a lógica em qualquer dia de execução.
const alinharJanelaCobranca = () =>
  db.query(
    `update public.config_cobranca_laudos
        set dia_semana = extract(isodow from focoh_interno.hoje())::int,
            hora_envio = '00:00',
            hora_escalonamento = '00:01',
            url_formulario_base = 'https://exemplo.invalid/laudos'
      where id = 1`
  );

await esperaSucesso(
  'na janela configurada, cobra um webhook por tipo de laudo + escalonamento',
  'coordenacao_tecnica',
  'criados=4 etapas=envio,escalonamento',
  async assumir => {
    await alinharJanelaCobranca();
    await db.exec('reset role');
    const { rows: r } = await db.query(
      'select focoh_interno.processar_cobranca_laudos()::text as criados'
    );
    await assumir('coordenacao_tecnica');
    const { rows: e } = await db.query(
      `select string_agg(etapa::text, ',' order by etapa) as etapas
         from public.execucoes_cobranca_laudos`
    );
    return `criados=${r[0].criados} etapas=${e[0].etapas}`;
  }
);

await esperaSucesso(
  'segunda passagem na mesma semana não cobra de novo (idempotência)',
  'coordenacao_tecnica',
  'primeira=4 segunda=0',
  async () => {
    await alinharJanelaCobranca();
    await db.exec('reset role');
    const { rows: a } = await db.query(
      'select focoh_interno.processar_cobranca_laudos()::text as n'
    );
    const { rows: b } = await db.query(
      'select focoh_interno.processar_cobranca_laudos()::text as n'
    );
    return `primeira=${a[0].n} segunda=${b[0].n}`;
  }
);

await esperaSucesso(
  'o link cobrado é parametrizado por paciente, tipo e semana',
  'coordenacao_tecnica',
  'link parametrizado',
  async () => {
    await alinharJanelaCobranca();
    await db.exec('reset role');
    await db.query('select focoh_interno.processar_cobranca_laudos()');
    const { rows } = await db.query(
      `select payload -> 'pacientes' -> 0 ->> 'url' as url
         from public.webhooks_saida
        where evento = 'laudos.cobranca' limit 1`
    );
    const url = rows[0].url ?? '';
    return /\?paciente=[0-9a-f-]+&tipo=\w+&semana=\d{4}-\d{2}-\d{2}$/.test(url)
      ? 'link parametrizado'
      : `formato inesperado: ${url}`;
  }
);

await esperaSucesso(
  'fora do dia configurado, nada é cobrado',
  'coordenacao_tecnica',
  '0',
  async () => {
    await db.query(
      `update public.config_cobranca_laudos
          set dia_semana = 1 + (extract(isodow from focoh_interno.hoje())::int % 7)
        where id = 1`
    );
    await db.exec('reset role');
    const { rows } = await db.query(
      'select focoh_interno.processar_cobranca_laudos()::text as n'
    );
    return rows[0].n;
  }
);

// ==========================================================================
// Agendamentos declarados
// ==========================================================================
console.log('\n== Agendamentos (pg_cron) ==');
await esperaSucesso(
  'as três rotinas estão agendadas',
  'coordenacao_tecnica',
  'focoh-cobranca-laudos,focoh-despachar-webhooks,focoh-reconciliar-webhooks',
  async () => {
    await db.exec('reset role');
    const { rows } = await db.query(
      "select string_agg(jobname, ',' order by jobname) as jobs from cron.job"
    );
    return rows[0].jobs;
  }
);

await esperaSucesso(
  'config do Protocolo Vermelho segue sem validação clínica assinada',
  'coordenacao_tecnica',
  'validado_clinicamente=false destinatarios_sem_whatsapp=5',
  async () => {
    const { rows } = await db.query(
      `select c.validado_clinicamente,
              (select count(*) from jsonb_array_elements(c.destinatarios) d
                where d ->> 'whatsapp' is null)::text as sem_whatsapp
         from public.config_protocolo_vermelho c where c.id = 1`
    );
    return `validado_clinicamente=${rows[0].validado_clinicamente} destinatarios_sem_whatsapp=${rows[0].sem_whatsapp}`;
  }
);

// --------------------------------------------------------------------------
const falhas = resultados.filter(r => !r.ok);
console.log(
  `\n== ${resultados.length - falhas.length}/${resultados.length} verificações passaram ==`
);
if (falhas.length) {
  console.log('Falhas:');
  falhas.forEach(f => console.log(`  - ${f.nome}: esperado ${f.esperado}, obtido ${f.obtido}`));
}
await db.close();
process.exit(falhas.length ? 1 : 0);
