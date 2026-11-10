-- =====================================================================
-- CONTROLE DE MÃO DE OBRA SEATRADE (requisições de mão de obra portuária)
-- Banco: Supabase (PostgreSQL 15+)
-- Executar inteiro no SQL Editor do Supabase. Pode ser rodado de novo (não duplica nada).
-- Depois, rodar o arquivo privado de carga (fornecedores e preços), que não vai para o GitHub.
-- =====================================================================
-- Regras de negócio garantidas pelo banco (não dependem da tela):
--   1. Preço do item é calculado no servidor (empresa x função x turno x tipo de dia,
--      pela vigência na data da requisição). O supervisor não digita valor.
--   2. Domingo/feriado é identificado automaticamente pela data (tabela feriados).
--   3. Trabalhador só entra em requisição se estiver ativo e habilitado na função.
--   4. Um trabalhador não pode estar em dois turnos sobrepostos no mesmo dia operacional.
--   5. Supervisor só edita requisição própria enquanto estiver ABERTA; aprovação é do ADMIN.
--   6. Tabela de preços e valores dos itens são visíveis apenas para ADMIN e FINANCEIRO.
--   7. Toda alteração relevante fica registrada na tabela auditoria.
--   8. FINANCEIRO fecha por fornecedor e período somente diárias APROVADAS; requisição em
--      fechamento fica travada (não reabre, não muda data/turno, não remove trabalhador).
--   9. Fechamento só é conferido com NF informada; diferença NF x sistema exige justificativa.
-- Perfis: ADMIN (tudo), SUPERVISOR (lança requisições), FINANCEIRO (consulta valores,
--         fecha fornecedores, confere NF e registra pagamento).
-- Dia operacional: começa às 07h e termina às 07h do dia seguinte
-- (o turno 01x07 pertence ao dia operacional da data informada).
-- =====================================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- 1. USUÁRIOS E PERFIS
-- ---------------------------------------------------------------------
create table if not exists public.usuarios (
  id         uuid primary key references auth.users(id) on delete cascade,
  nome       text not null default '',
  email      text,
  perfil     text not null default 'SUPERVISOR',
  ativo      boolean not null default false,   -- conta nasce bloqueada; o admin libera
  criado_em  timestamptz not null default now()
);
alter table public.usuarios drop constraint if exists usuarios_perfil_check;
alter table public.usuarios add constraint usuarios_perfil_check
  check (perfil in ('ADMIN','SUPERVISOR','FINANCEIRO'));

-- Cria o registro em usuarios sempre que alguém é criado no Auth
create or replace function public.fn_novo_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.usuarios (id, nome, email)
  values (new.id, coalesce(new.raw_user_meta_data->>'nome', split_part(new.email,'@',1)), new.email)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists trg_novo_usuario on auth.users;
create trigger trg_novo_usuario after insert on auth.users
  for each row execute function public.fn_novo_usuario();

create or replace function public.meu_perfil()
returns text language sql stable security definer set search_path = public as $$
  select perfil from public.usuarios where id = auth.uid() and ativo
$$;
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_perfil() = 'ADMIN', false)
$$;
create or replace function public.is_ativo()
returns boolean language sql stable security definer set search_path = public as $$
  select public.meu_perfil() is not null
$$;
-- Quem enxerga valores em R$ (ADMIN e FINANCEIRO)
create or replace function public.ve_valores()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_perfil() in ('ADMIN','FINANCEIRO'), false)
$$;
-- Quem lança requisições (ADMIN e SUPERVISOR)
create or replace function public.pode_requisitar()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_perfil() in ('ADMIN','SUPERVISOR'), false)
$$;

-- ---------------------------------------------------------------------
-- 2. CADASTROS
-- ---------------------------------------------------------------------
create table if not exists public.empresas (
  id              bigint generated always as identity primary key,
  nome            text not null unique,
  cnpj            text,
  contato         text,
  telefone        text,
  email           text,
  fornece_epi     boolean not null default false,
  fornece_lanche  boolean not null default false,
  observacao      text,
  ativo           boolean not null default true,
  criado_em       timestamptz not null default now()
);

create table if not exists public.funcoes (
  id     bigint generated always as identity primary key,
  nome   text not null unique,
  ativo  boolean not null default true
);

create table if not exists public.turnos (
  id           bigint generated always as identity primary key,
  codigo       text not null unique,                 -- ex.: 07x13
  descricao    text not null,
  hora_inicio  int  not null check (hora_inicio between 0 and 23),
  horas        int  not null check (horas between 1 and 24),
  periodo      text not null check (periodo in ('DIURNO','NOTURNO')),
  ativo        boolean not null default true
);

create table if not exists public.armazens (
  id     bigint generated always as identity primary key,
  nome   text not null unique,
  ativo  boolean not null default true
);

create table if not exists public.navios (
  id          bigint generated always as identity primary key,
  nome        text not null,
  viagem      text,
  eta         date,
  observacao  text,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now(),
  unique nulls not distinct (nome, viagem)
);

create table if not exists public.feriados (
  data       date primary key,
  descricao  text not null
);

create table if not exists public.trabalhadores (
  id          bigint generated always as identity primary key,
  nome        text not null,
  cpf         text unique,
  cnpj_mei    text,
  empresa_id  bigint not null references public.empresas(id),
  telefone    text,
  chave_pix   text,
  observacao  text,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);

-- Funções em que cada trabalhador está habilitado (um trabalhador pode ter várias)
create table if not exists public.trabalhador_funcoes (
  trabalhador_id  bigint not null references public.trabalhadores(id) on delete cascade,
  funcao_id       bigint not null references public.funcoes(id),
  primary key (trabalhador_id, funcao_id)
);

-- ---------------------------------------------------------------------
-- 3. TABELA DE PREÇOS (com vigência)
-- ---------------------------------------------------------------------
create table if not exists public.tabela_precos (
  id               bigint generated always as identity primary key,
  empresa_id       bigint not null references public.empresas(id),
  funcao_id        bigint not null references public.funcoes(id),
  turno_id         bigint not null references public.turnos(id),
  tipo_dia         text   not null check (tipo_dia in ('UTIL','DOM_FER')),
  valor            numeric(12,2) not null check (valor >= 0),
  vigencia_inicio  date   not null default date '2026-01-01',
  vigencia_fim     date,
  criado_em        timestamptz not null default now(),
  check (vigencia_fim is null or vigencia_fim >= vigencia_inicio),
  -- impede duas vigências sobrepostas para a mesma combinação
  exclude using gist (
    empresa_id with =, funcao_id with =, turno_id with =, tipo_dia with =,
    daterange(vigencia_inicio, coalesce(vigencia_fim, 'infinity'::date), '[]') with &&
  )
);

-- ---------------------------------------------------------------------
-- 4. REQUISIÇÕES (cabeçalho) E ITENS (um trabalhador por linha)
-- ---------------------------------------------------------------------
create table if not exists public.requisicoes (
  id                   bigint generated always as identity primary key,
  data                 date   not null,
  turno_id             bigint not null references public.turnos(id),
  navio_id             bigint not null references public.navios(id),
  armazem_id           bigint not null references public.armazens(id),
  tipo_dia             text   not null default 'UTIL' check (tipo_dia in ('UTIL','DOM_FER')),
  supervisor_id        uuid   not null default auth.uid() references public.usuarios(id),
  status               text   not null default 'ABERTA' check (status in ('ABERTA','APROVADA','CANCELADA')),
  observacao           text,
  motivo_cancelamento  text,
  aprovado_por         uuid references public.usuarios(id),
  aprovado_em          timestamptz,
  criado_em            timestamptz not null default now(),
  atualizado_em        timestamptz not null default now()
);
create index if not exists ix_req_data  on public.requisicoes(data);
create index if not exists ix_req_navio on public.requisicoes(navio_id);

create table if not exists public.requisicao_itens (
  id              bigint generated always as identity primary key,
  requisicao_id   bigint not null references public.requisicoes(id) on delete cascade,
  trabalhador_id  bigint not null references public.trabalhadores(id),
  funcao_id       bigint not null references public.funcoes(id),
  empresa_id      bigint references public.empresas(id),   -- preenchido pelo banco
  horas           int,                                      -- preenchido pelo banco
  valor_unitario  numeric(12,2),                            -- preenchido pelo banco
  observacao      text,
  criado_em       timestamptz not null default now(),
  unique (requisicao_id, trabalhador_id)
);
create index if not exists ix_item_trab on public.requisicao_itens(trabalhador_id);

-- ---------------------------------------------------------------------
-- 4b. FECHAMENTOS (FINANCEIRO): lote de diárias aprovadas de um fornecedor x período
-- ---------------------------------------------------------------------
create table if not exists public.fechamentos (
  id              bigint generated always as identity primary key,
  empresa_id      bigint not null references public.empresas(id),
  data_inicio     date   not null,
  data_fim        date   not null,
  status          text   not null default 'EM_CONFERENCIA'
                  check (status in ('EM_CONFERENCIA','CONFERIDO','PAGO')),
  nf_numero       text,
  nf_data         date,
  nf_valor        numeric(12,2) check (nf_valor is null or nf_valor >= 0),
  valor_sistema   numeric(12,2) not null default 0,   -- soma das diárias do lote (gravada pelo banco)
  justificativa   text,                               -- obrigatória se NF <> sistema
  data_pagamento  date,
  observacao      text,
  criado_por      uuid references public.usuarios(id),
  criado_em       timestamptz not null default now(),
  conferido_por   uuid references public.usuarios(id),
  conferido_em    timestamptz,
  pago_por        uuid references public.usuarios(id),
  pago_em         timestamptz,
  check (data_fim >= data_inicio)
);

alter table public.requisicao_itens
  add column if not exists fechamento_id bigint references public.fechamentos(id);
create index if not exists ix_item_fech on public.requisicao_itens(fechamento_id);

-- ---------------------------------------------------------------------
-- 5. AUDITORIA
-- ---------------------------------------------------------------------
create table if not exists public.auditoria (
  id             bigint generated always as identity primary key,
  tabela         text not null,
  registro_id    text,
  acao           text not null,
  usuario_id     uuid,
  dados_antigos  jsonb,
  dados_novos    jsonb,
  em             timestamptz not null default now()
);

create or replace function public.fn_auditoria()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_old jsonb; v_new jsonb;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  insert into public.auditoria (tabela, registro_id, acao, usuario_id, dados_antigos, dados_novos)
  values (tg_table_name,
          coalesce(v_new->>'id', v_old->>'id', v_new->>'trabalhador_id', v_old->>'trabalhador_id', v_new->>'data', v_old->>'data'),
          tg_op, auth.uid(), v_old, v_new);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['usuarios','empresas','trabalhadores','trabalhador_funcoes','tabela_precos',
                           'feriados','turnos','requisicoes','requisicao_itens','fechamentos'] loop
    execute format('drop trigger if exists trg_audit on public.%I', t);
    execute format('create trigger trg_audit after insert or update or delete on public.%I
                    for each row execute function public.fn_auditoria()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 6. REGRAS DE NEGÓCIO (TRIGGERS)
-- ---------------------------------------------------------------------
create or replace function public.fn_tipo_dia(p_data date)
returns text language sql stable security definer set search_path = public as $$
  select case when extract(dow from p_data) = 0
                or exists (select 1 from public.feriados f where f.data = p_data)
              then 'DOM_FER' else 'UTIL' end
$$;

-- Início do turno contado a partir das 07h (dia operacional)
create or replace function public.fn_inicio_operacional(p_hora int)
returns int language sql immutable as $$ select ((p_hora - 7 + 24) % 24) $$;

-- Cabeçalho: tipo de dia, carimbos de aprovação e proteção de status
create or replace function public.fn_requisicao_antes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.tipo_dia := public.fn_tipo_dia(new.data);
  new.atualizado_em := now();

  if tg_op = 'INSERT' then
    new.status := 'ABERTA';
    new.aprovado_por := null; new.aprovado_em := null;
    return new;
  end if;

  if (new.status, new.data, new.turno_id, new.navio_id, new.armazem_id)
       is distinct from (old.status, old.data, old.turno_id, old.navio_id, old.armazem_id)
     and exists (select 1 from public.requisicao_itens i where i.requisicao_id = new.id and i.fechamento_id is not null) then
    raise exception 'Requisição incluída em fechamento do financeiro. Desfaça o fechamento antes de alterar.';
  end if;

  if new.status = 'APROVADA' and old.status <> 'APROVADA' then
    if not public.is_admin() then raise exception 'Somente o administrador pode aprovar requisições.'; end if;
    if not exists (select 1 from public.requisicao_itens i where i.requisicao_id = new.id) then
      raise exception 'Não é possível aprovar uma requisição sem trabalhadores.';
    end if;
    new.aprovado_por := auth.uid(); new.aprovado_em := now();
  elsif new.status <> 'APROVADA' then
    new.aprovado_por := null; new.aprovado_em := null;
  end if;

  if new.status = 'CANCELADA' and coalesce(trim(new.motivo_cancelamento),'') = '' then
    raise exception 'Informe o motivo do cancelamento.';
  end if;
  return new;
end $$;

drop trigger if exists trg_requisicao_antes on public.requisicoes;
create trigger trg_requisicao_antes before insert or update on public.requisicoes
  for each row execute function public.fn_requisicao_antes();

-- Se mudar data ou turno, reprecifica e revalida os itens
create or replace function public.fn_requisicao_depois()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.data is distinct from old.data or new.turno_id is distinct from old.turno_id then
    update public.requisicao_itens set funcao_id = funcao_id where requisicao_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists trg_requisicao_depois on public.requisicoes;
create trigger trg_requisicao_depois after update on public.requisicoes
  for each row execute function public.fn_requisicao_depois();

-- Item: habilitação, empresa, horas, preço e conflito de turno
create or replace function public.fn_item_antes()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r   public.requisicoes%rowtype;
  t   public.turnos%rowtype;
  tb  public.trabalhadores%rowtype;
  v_valor numeric(12,2);
  v_ini int; v_fim int;
  v_conflito text;
begin
  -- vínculo com fechamento: só pelas funções do financeiro, sem reprecificar
  if tg_op = 'UPDATE' and new.fechamento_id is distinct from old.fechamento_id then
    if coalesce(current_setting('app.fechamento', true), '') <> 'on' then
      raise exception 'O vínculo com fechamento é feito apenas pela tela de Fechamentos.';
    end if;
    return new;
  end if;
  if tg_op = 'UPDATE' and old.fechamento_id is not null then
    raise exception 'Diária incluída em fechamento do financeiro; não pode ser alterada.';
  end if;
  if tg_op = 'INSERT' then new.fechamento_id := null; end if;

  select * into r  from public.requisicoes  where id = new.requisicao_id;
  select * into t  from public.turnos       where id = r.turno_id;
  select * into tb from public.trabalhadores where id = new.trabalhador_id;

  if not tb.ativo then raise exception 'Trabalhador % está inativo.', tb.nome; end if;

  if not exists (select 1 from public.trabalhador_funcoes
                 where trabalhador_id = tb.id and funcao_id = new.funcao_id) then
    raise exception '% não está habilitado nesta função.', tb.nome;
  end if;

  new.empresa_id := tb.empresa_id;
  new.horas      := t.horas;

  select p.valor into v_valor
    from public.tabela_precos p
   where p.empresa_id = tb.empresa_id and p.funcao_id = new.funcao_id
     and p.turno_id = r.turno_id and p.tipo_dia = r.tipo_dia
     and r.data >= p.vigencia_inicio and (p.vigencia_fim is null or r.data <= p.vigencia_fim);

  if v_valor is null then
    raise exception 'Sem preço cadastrado para a empresa de % nesta função/turno (%).', tb.nome,
      case r.tipo_dia when 'DOM_FER' then 'domingo/feriado' else 'dia útil' end;
  end if;
  new.valor_unitario := v_valor;

  v_ini := public.fn_inicio_operacional(t.hora_inicio);
  v_fim := v_ini + t.horas;

  select t2.codigo into v_conflito
    from public.requisicao_itens i2
    join public.requisicoes r2 on r2.id = i2.requisicao_id
    join public.turnos t2      on t2.id = r2.turno_id
   where i2.trabalhador_id = new.trabalhador_id
     and i2.id <> coalesce(new.id, -1)
     and r2.data = r.data
     and r2.status <> 'CANCELADA'
     and public.fn_inicio_operacional(t2.hora_inicio) < v_fim
     and v_ini < public.fn_inicio_operacional(t2.hora_inicio) + t2.horas
   limit 1;

  if v_conflito is not null then
    raise exception '% já está escalado no turno % deste dia.', tb.nome, v_conflito;
  end if;
  return new;
end $$;

drop trigger if exists trg_item_antes on public.requisicao_itens;
create trigger trg_item_antes before insert or update on public.requisicao_itens
  for each row execute function public.fn_item_antes();

create or replace function public.fn_item_excluir()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.fechamento_id is not null then
    raise exception 'Diária incluída em fechamento do financeiro; não pode ser excluída.';
  end if;
  return old;
end $$;

drop trigger if exists trg_item_excluir on public.requisicao_itens;
create trigger trg_item_excluir before delete on public.requisicao_itens
  for each row execute function public.fn_item_excluir();

-- Fechamento: status, carimbos e consistência da NF
create or replace function public.fn_fechamento_antes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- período, empresa e valor do sistema não são editáveis
  new.empresa_id := old.empresa_id; new.data_inicio := old.data_inicio; new.data_fim := old.data_fim;
  new.criado_por := old.criado_por; new.criado_em := old.criado_em;
  select coalesce(sum(i.valor_unitario), 0) into new.valor_sistema
    from public.requisicao_itens i where i.fechamento_id = new.id;

  if old.status <> 'EM_CONFERENCIA' and new.status = old.status
     and (new.nf_numero, new.nf_data, new.nf_valor, new.justificativa)
         is distinct from (old.nf_numero, old.nf_data, old.nf_valor, old.justificativa) then
    raise exception 'Volte o fechamento para "Em conferência" para alterar os dados da NF.';
  end if;

  if old.status = 'PAGO' and new.status <> 'PAGO' and not public.is_admin() then
    raise exception 'Somente o administrador pode estornar um pagamento.';
  end if;

  if new.status in ('CONFERIDO','PAGO') then
    if coalesce(trim(new.nf_numero), '') = '' or new.nf_valor is null then
      raise exception 'Informe o número e o valor da NF antes de conferir.';
    end if;
    if new.nf_valor <> new.valor_sistema and coalesce(trim(new.justificativa), '') = '' then
      raise exception 'NF (R$ %) diferente do sistema (R$ %). Informe a justificativa.', new.nf_valor, new.valor_sistema;
    end if;
  end if;

  if new.status = 'PAGO' and old.status = 'EM_CONFERENCIA' then
    raise exception 'Confira o fechamento antes de registrar o pagamento.';
  end if;

  if new.status = 'EM_CONFERENCIA' then
    new.conferido_por := null; new.conferido_em := null;
  elsif old.status = 'EM_CONFERENCIA' then
    new.conferido_por := auth.uid(); new.conferido_em := now();
  end if;

  if new.status = 'PAGO' then
    if old.status <> 'PAGO' then
      new.pago_por := auth.uid(); new.pago_em := now();
      new.data_pagamento := coalesce(new.data_pagamento, current_date);
    end if;
  else
    new.pago_por := null; new.pago_em := null; new.data_pagamento := null;
  end if;
  return new;
end $$;

drop trigger if exists trg_fechamento_antes on public.fechamentos;
create trigger trg_fechamento_antes before update on public.fechamentos
  for each row execute function public.fn_fechamento_antes();

-- Gera o fechamento: inclui todas as diárias APROVADAS do fornecedor no período ainda não fechadas
create or replace function public.gerar_fechamento(p_empresa_id bigint, p_inicio date, p_fim date)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not public.ve_valores() then raise exception 'Você não tem permissão para esta operação.'; end if;
  if p_fim < p_inicio then raise exception 'A data final é anterior à inicial.'; end if;
  if not exists (select 1 from public.requisicao_itens i join public.requisicoes r on r.id = i.requisicao_id
                  where i.empresa_id = p_empresa_id and r.status = 'APROVADA'
                    and r.data between p_inicio and p_fim and i.fechamento_id is null) then
    raise exception 'Nenhuma diária aprovada e ainda não fechada para esta empresa no período.';
  end if;

  insert into public.fechamentos (empresa_id, data_inicio, data_fim, criado_por)
  values (p_empresa_id, p_inicio, p_fim, auth.uid()) returning id into v_id;

  perform set_config('app.fechamento', 'on', true);
  update public.requisicao_itens i set fechamento_id = v_id
    from public.requisicoes r
   where r.id = i.requisicao_id and i.empresa_id = p_empresa_id and r.status = 'APROVADA'
     and r.data between p_inicio and p_fim and i.fechamento_id is null;
  perform set_config('app.fechamento', 'off', true);

  update public.fechamentos set observacao = observacao where id = v_id;  -- grava valor_sistema
  return v_id;
end $$;

-- Desfaz um fechamento ainda em conferência (libera as diárias)
create or replace function public.desfazer_fechamento(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.ve_valores() then raise exception 'Você não tem permissão para esta operação.'; end if;
  if not exists (select 1 from public.fechamentos where id = p_id and status = 'EM_CONFERENCIA') then
    raise exception 'Só é possível desfazer um fechamento "Em conferência".';
  end if;
  perform set_config('app.fechamento', 'on', true);
  update public.requisicao_itens set fechamento_id = null where fechamento_id = p_id;
  perform set_config('app.fechamento', 'off', true);
  delete from public.fechamentos where id = p_id;
end $$;

revoke execute on function public.gerar_fechamento(bigint, date, date) from public, anon;
revoke execute on function public.desfazer_fechamento(bigint) from public, anon;
grant execute on function public.gerar_fechamento(bigint, date, date) to authenticated;
grant execute on function public.desfazer_fechamento(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 7. VIEWS DE CONSULTA E RELATÓRIO
--    (valores aparecem somente para ADMIN e FINANCEIRO)
--    Colunas novas entram sempre no FIM da view (create or replace não reordena).
-- ---------------------------------------------------------------------
create or replace view public.vw_requisicoes as
select r.id, r.data, r.tipo_dia, r.status, r.observacao, r.motivo_cancelamento,
       r.turno_id, t.codigo as turno, t.periodo, t.horas as horas_turno,
       r.navio_id, n.nome as navio, n.viagem,
       r.armazem_id, a.nome as armazem,
       r.supervisor_id, u.nome as supervisor,
       r.aprovado_em, ua.nome as aprovado_por_nome,
       r.criado_em,
       (select count(*) from public.requisicao_itens i where i.requisicao_id = r.id)::int as qtd_trabalhadores,
       case when public.ve_valores()
            then (select coalesce(sum(i.valor_unitario),0) from public.requisicao_itens i where i.requisicao_id = r.id)
       end as valor_total,
       exists (select 1 from public.requisicao_itens i where i.requisicao_id = r.id and i.fechamento_id is not null) as em_fechamento
  from public.requisicoes r
  join public.turnos   t on t.id = r.turno_id
  join public.navios   n on n.id = r.navio_id
  join public.armazens a on a.id = r.armazem_id
  left join public.usuarios u  on u.id  = r.supervisor_id
  left join public.usuarios ua on ua.id = r.aprovado_por
 where public.is_ativo();

create or replace view public.vw_itens as
select i.id, i.requisicao_id, r.data, r.tipo_dia, r.status,
       r.turno_id, t.codigo as turno, t.periodo, i.horas,
       r.navio_id, n.nome as navio, n.viagem,
       r.armazem_id, a.nome as armazem,
       i.trabalhador_id, tb.nome as trabalhador, tb.cnpj_mei,
       i.funcao_id, f.nome as funcao,
       i.empresa_id, e.nome as empresa,
       r.supervisor_id, u.nome as supervisor,
       case when public.ve_valores() then i.valor_unitario end as valor,
       i.observacao,
       i.fechamento_id
  from public.requisicao_itens i
  join public.requisicoes   r  on r.id  = i.requisicao_id
  join public.turnos        t  on t.id  = r.turno_id
  join public.navios        n  on n.id  = r.navio_id
  join public.armazens      a  on a.id  = r.armazem_id
  join public.trabalhadores tb on tb.id = i.trabalhador_id
  join public.funcoes       f  on f.id  = i.funcao_id
  join public.empresas      e  on e.id  = i.empresa_id
  left join public.usuarios u  on u.id  = r.supervisor_id
 where public.is_ativo();

create or replace view public.vw_fechamentos as
select f.id, f.empresa_id, e.nome as empresa, f.data_inicio, f.data_fim, f.status,
       f.nf_numero, f.nf_data, f.nf_valor, f.valor_sistema,
       case when f.nf_valor is not null then f.nf_valor - f.valor_sistema end as diferenca,
       f.justificativa, f.data_pagamento, f.observacao,
       (select count(*) from public.requisicao_itens i where i.fechamento_id = f.id)::int as qtd_diarias,
       (select coalesce(sum(i.horas),0) from public.requisicao_itens i where i.fechamento_id = f.id)::int as horas,
       f.criado_em, uc.nome as criado_por_nome,
       f.conferido_em, uf.nome as conferido_por_nome,
       f.pago_em, up.nome as pago_por_nome
  from public.fechamentos f
  join public.empresas e on e.id = f.empresa_id
  left join public.usuarios uc on uc.id = f.criado_por
  left join public.usuarios uf on uf.id = f.conferido_por
  left join public.usuarios up on up.id = f.pago_por
 where public.ve_valores();

create or replace view public.vw_auditoria as
select a.id, a.tabela, a.registro_id, a.acao, a.usuario_id, u.nome as usuario,
       a.dados_antigos, a.dados_novos, a.em
  from public.auditoria a
  left join public.usuarios u on u.id = a.usuario_id
 where public.ve_valores();

-- ---------------------------------------------------------------------
-- 8. SEGURANÇA (RLS)
-- ---------------------------------------------------------------------
alter table public.usuarios            enable row level security;
alter table public.empresas            enable row level security;
alter table public.funcoes             enable row level security;
alter table public.turnos              enable row level security;
alter table public.armazens            enable row level security;
alter table public.navios              enable row level security;
alter table public.feriados            enable row level security;
alter table public.trabalhadores       enable row level security;
alter table public.trabalhador_funcoes enable row level security;
alter table public.tabela_precos       enable row level security;
alter table public.requisicoes         enable row level security;
alter table public.requisicao_itens    enable row level security;
alter table public.fechamentos         enable row level security;
alter table public.auditoria           enable row level security;

-- Usuários
drop policy if exists usu_sel on public.usuarios;
create policy usu_sel on public.usuarios for select using (id = auth.uid() or public.is_admin());
drop policy if exists usu_upd on public.usuarios;
create policy usu_upd on public.usuarios for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists usu_del on public.usuarios;
create policy usu_del on public.usuarios for delete using (public.is_admin());

-- Cadastros: leitura para usuários ativos, escrita só ADMIN
do $$
declare t text;
begin
  foreach t in array array['empresas','funcoes','turnos','armazens','feriados','trabalhadores','trabalhador_funcoes'] loop
    execute format('drop policy if exists cad_sel on public.%I', t);
    execute format('create policy cad_sel on public.%I for select using (public.is_ativo())', t);
    execute format('drop policy if exists cad_adm on public.%I', t);
    execute format('create policy cad_adm on public.%I for all using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

-- Navios: quem requisita pode cadastrar navio novo; editar/excluir só ADMIN
drop policy if exists nav_sel on public.navios;
create policy nav_sel on public.navios for select using (public.is_ativo());
drop policy if exists nav_ins on public.navios;
create policy nav_ins on public.navios for insert with check (public.pode_requisitar());
drop policy if exists nav_upd on public.navios;
create policy nav_upd on public.navios for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists nav_del on public.navios;
create policy nav_del on public.navios for delete using (public.is_admin());

-- Tabela de preços: ADMIN edita; FINANCEIRO consulta
drop policy if exists pre_adm on public.tabela_precos;
create policy pre_adm on public.tabela_precos for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists pre_sel on public.tabela_precos;
create policy pre_sel on public.tabela_precos for select using (public.ve_valores());

-- Requisições (FINANCEIRO só consulta)
drop policy if exists req_sel on public.requisicoes;
create policy req_sel on public.requisicoes for select using (public.is_ativo());
drop policy if exists req_ins on public.requisicoes;
create policy req_ins on public.requisicoes for insert
  with check (public.pode_requisitar() and supervisor_id = auth.uid());
drop policy if exists req_upd on public.requisicoes;
create policy req_upd on public.requisicoes for update
  using (public.is_admin() or (supervisor_id = auth.uid() and status = 'ABERTA' and public.pode_requisitar()))
  with check (public.is_admin() or (supervisor_id = auth.uid() and status in ('ABERTA','CANCELADA')));
drop policy if exists req_del on public.requisicoes;
create policy req_del on public.requisicoes for delete using (public.is_admin());

-- Itens
drop policy if exists item_sel on public.requisicao_itens;
create policy item_sel on public.requisicao_itens for select using (public.is_ativo());
drop policy if exists item_mod on public.requisicao_itens;
create policy item_mod on public.requisicao_itens for all
  using (public.is_admin() or exists (select 1 from public.requisicoes r
          where r.id = requisicao_id and r.supervisor_id = auth.uid() and r.status = 'ABERTA' and public.pode_requisitar()))
  with check (public.is_admin() or exists (select 1 from public.requisicoes r
          where r.id = requisicao_id and r.supervisor_id = auth.uid() and r.status = 'ABERTA' and public.pode_requisitar()));

-- Fechamentos: ADMIN e FINANCEIRO consultam e atualizam (NF, conferência, pagamento).
-- Criar e desfazer apenas pelas funções gerar_fechamento / desfazer_fechamento.
drop policy if exists fec_sel on public.fechamentos;
create policy fec_sel on public.fechamentos for select using (public.ve_valores());
drop policy if exists fec_upd on public.fechamentos;
create policy fec_upd on public.fechamentos for update using (public.ve_valores()) with check (public.ve_valores());

-- Auditoria: leitura ADMIN e FINANCEIRO (gravação apenas via trigger)
drop policy if exists aud_sel on public.auditoria;
create policy aud_sel on public.auditoria for select using (public.ve_valores());

-- Permissões explícitas (não depende do padrão do projeto Supabase).
-- Quem pode o quê em cada linha continua decidido pelas políticas (RLS) acima.
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on
  public.usuarios, public.empresas, public.funcoes, public.turnos, public.armazens, public.navios,
  public.feriados, public.trabalhadores, public.trabalhador_funcoes, public.tabela_precos,
  public.requisicoes
  to authenticated;
grant insert, update, delete on public.requisicao_itens to authenticated;
grant select, update on public.fechamentos to authenticated;
grant select on public.auditoria to authenticated;
revoke insert, update, delete on public.auditoria from anon, authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.meu_perfil(), public.is_admin(), public.is_ativo(), public.ve_valores(),
  public.pode_requisitar(), public.fn_tipo_dia(date), public.fn_inicio_operacional(int)
  to anon, authenticated;

-- O valor do item não é legível direto na tabela: leitura de valores só pelas views
revoke select on public.requisicao_itens from anon, authenticated;
grant select (id, requisicao_id, trabalhador_id, funcao_id, empresa_id, horas, observacao, criado_em, fechamento_id)
  on public.requisicao_itens to authenticated;
revoke insert, delete on public.fechamentos from anon, authenticated;
revoke all on public.vw_requisicoes, public.vw_itens, public.vw_fechamentos, public.vw_auditoria from anon;
grant select on public.vw_requisicoes, public.vw_itens, public.vw_fechamentos, public.vw_auditoria to authenticated;

-- ---------------------------------------------------------------------
-- 9. CARGA INICIAL (somente dados genéricos)
--    Fornecedores e tabela de preços NÃO ficam neste arquivo (ele é público):
--    são carregados por um arquivo privado, rodado direto no SQL Editor.
-- ---------------------------------------------------------------------
insert into public.funcoes (nome) values
  ('OPERADOR DE EMPILHADEIRA'), ('CONFERENTE'), ('AUXILIAR')
on conflict (nome) do nothing;

insert into public.turnos (codigo, descricao, hora_inicio, horas, periodo) values
  ('07x13', '07h às 13h (6h diurno)',   7,  6, 'DIURNO'),
  ('13x19', '13h às 19h (6h diurno)',  13,  6, 'DIURNO'),
  ('19x01', '19h às 01h (6h noturno)', 19,  6, 'NOTURNO'),
  ('01x07', '01h às 07h (6h noturno)',  1,  6, 'NOTURNO'),
  ('07x19', '07h às 19h (12h diurno)',  7, 12, 'DIURNO'),
  ('19x07', '19h às 07h (12h noturno)',19, 12, 'NOTURNO')
on conflict (codigo) do nothing;


insert into public.armazens (nome) values
  ('ARMAZÉM 1'), ('ARMAZÉM 2'), ('ARMAZÉM 3'), ('ARMAZÉM 4'), ('PÁTIO')
on conflict (nome) do nothing;

insert into public.feriados (data, descricao) values
  ('2026-01-01','Confraternização Universal'), ('2026-04-03','Sexta-feira Santa'),
  ('2026-04-21','Tiradentes'), ('2026-05-01','Dia do Trabalho'), ('2026-06-04','Corpus Christi'),
  ('2026-09-07','Independência'), ('2026-10-12','Nossa Senhora Aparecida'), ('2026-11-02','Finados'),
  ('2026-11-15','Proclamação da República'), ('2026-11-20','Consciência Negra'), ('2026-12-25','Natal'),
  ('2027-01-01','Confraternização Universal'), ('2027-03-26','Sexta-feira Santa'),
  ('2027-04-21','Tiradentes'), ('2027-05-01','Dia do Trabalho'), ('2027-05-27','Corpus Christi'),
  ('2027-09-07','Independência'), ('2027-10-12','Nossa Senhora Aparecida'), ('2027-11-02','Finados'),
  ('2027-11-15','Proclamação da República'), ('2027-11-20','Consciência Negra'), ('2027-12-25','Natal')
on conflict (data) do nothing;


-- ---------------------------------------------------------------------
-- 10. PRIMEIRO ADMINISTRADOR
-- Depois de criar seu usuário em Authentication > Users, rode (trocando o e-mail):
--   update public.usuarios set perfil = 'ADMIN', ativo = true, nome = 'Seu Nome'
--    where email = 'seu.email@empresa.com.br';
-- Os demais (SUPERVISOR e FINANCEIRO) são criados pela tela Usuários do sistema.
-- ---------------------------------------------------------------------
