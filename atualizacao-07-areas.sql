-- ==========================================================================
-- KANBAN GMAP | Atualização 07: Áreas de trabalho e visibilidade dos quadros
-- Execute no SQL Editor do Supabase (depois da atualização 06).
-- Pode ser executada mais de uma vez sem problema.
--
-- O que muda:
--   * Novas "áreas de trabalho": agrupam quadros e pessoas (ex.: Núcleo 1).
--     Só o administrador do sistema cria áreas; administradores da área
--     gerenciam os membros dela.
--   * Cada quadro pertence a uma área e tem uma visibilidade:
--       private   -> só os membros do quadro
--       workspace -> membros do quadro + todos os membros da área (só leitura)
--       org       -> membros do quadro + todos os usuários ativos (só leitura)
--   * O administrador do sistema deixa de ver o conteúdo de todos os quadros.
--     Ele vê a lista de quadros (nome, área, donos) na Administração e pode
--     "assumir acesso" a um quadro (por exemplo, quando o dono saiu); essa ação
--     fica registrada no histórico de administração.
--   * Quem vê um quadro só pela visibilidade (sem ser membro) é "visitante":
--     lê tudo, mas não edita, não comenta e não cria cartões por template.
--   * Migração: cria a área "GMAP" com todos os usuários ativos, coloca nela
--     todos os quadros existentes como "privados" (ninguém passa a ver um
--     quadro que antes não via) e a define como área padrão para novos usuários.
-- ==========================================================================

-- --------------------------------------------------------------------------
-- [A] TABELAS
-- --------------------------------------------------------------------------
create table if not exists public.workspaces (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  description text not null default '',
  color       text not null default '#1f4e79',
  created_by  uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists uq_workspaces_name on public.workspaces (lower(trim(name)));

create table if not exists public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  role         text not null default 'member' check (role in ('admin','member')),
  added_by     uuid default auth.uid(),
  added_at     timestamptz not null default now(),
  primary key (workspace_id, user_id)
);
create index if not exists idx_ws_members_user on public.workspace_members (user_id);

alter table public.boards add column if not exists workspace_id uuid references public.workspaces(id) on delete restrict;
alter table public.boards add column if not exists visibility text not null default 'private';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'boards_visibility_check') then
    alter table public.boards add constraint boards_visibility_check check (visibility in ('private','workspace','org'));
  end if;
end $$;
create index if not exists idx_boards_workspace on public.boards (workspace_id);

alter table public.app_config add column if not exists default_workspace uuid references public.workspaces(id) on delete set null;

-- --------------------------------------------------------------------------
-- [B] FUNÇÕES DE PERMISSÃO (substituem as anteriores)
-- --------------------------------------------------------------------------
-- Papel do usuário logado na área: admin | member | null
create or replace function public.ws_role(w uuid) returns text
language sql stable security definer set search_path = public as $$
  select m.role from workspace_members m join profiles p on p.id = m.user_id
   where m.workspace_id = w and m.user_id = auth.uid() and p.status = 'active';
$$;

create or replace function public.is_ws_member(w uuid) returns boolean
language sql stable as $$ select public.ws_role(w) is not null; $$;

-- Gerencia membros e dados da área: administrador do sistema ou administrador da área
create or replace function public.can_manage_ws(w uuid) returns boolean
language sql stable as $$ select public.is_admin() or coalesce(public.ws_role(w) = 'admin', false); $$;

-- Papel do usuário logado no quadro: owner | editor | viewer | visitor | null
--   visitor = não é membro, mas o quadro é visível para a área ou para o setor
create or replace function public.board_role(b uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select m.role from board_members m join profiles p on p.id = m.user_id
      where m.board_id = b and m.user_id = auth.uid() and p.status = 'active'),
    (select 'visitor' from boards bo
      where bo.id = b and public.is_active_user()
        and (bo.visibility = 'org'
             or (bo.visibility = 'workspace' and public.is_ws_member(bo.workspace_id))))
  );
$$;

create or replace function public.can_view_board(b uuid) returns boolean
language sql stable as $$ select public.board_role(b) is not null; $$;

create or replace function public.can_edit_board(b uuid) returns boolean
language sql stable as $$ select coalesce(public.board_role(b) in ('owner','editor'), false); $$;

create or replace function public.can_manage_board(b uuid) returns boolean
language sql stable as $$ select coalesce(public.board_role(b) = 'owner', false); $$;

-- Membro do quadro (inclui leitor): pode comentar e criar cartões por template
create or replace function public.can_participate_board(b uuid) returns boolean
language sql stable as $$ select coalesce(public.board_role(b) in ('owner','editor','viewer'), false); $$;

-- --------------------------------------------------------------------------
-- [C] MIGRAÇÃO DOS DADOS EXISTENTES
-- --------------------------------------------------------------------------
do $$
declare w uuid;
begin
  select default_workspace into w from app_config where id = 1;
  if w is null then select id into w from workspaces order by created_at limit 1; end if;
  if w is null then
    insert into workspaces (name, description, created_by)
    values ('GMAP', 'Área geral da Gerência de Material e Patrimônio',
            (select id from profiles where is_admin and status = 'active' order by created_at limit 1))
    returning id into w;
  end if;
  insert into workspace_members (workspace_id, user_id, role, added_by)
  select w, p.id, case when p.is_admin then 'admin' else 'member' end, null
    from profiles p where p.status = 'active'
  on conflict do nothing;
  update boards set workspace_id = w where workspace_id is null;
  update app_config set default_workspace = coalesce(default_workspace, w) where id = 1;
end $$;

-- --------------------------------------------------------------------------
-- [D] REGRAS DE CONSISTÊNCIA
-- --------------------------------------------------------------------------
-- Quadro precisa estar numa área da qual quem cria ou move seja membro
create or replace function public.boards_check_workspace() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.workspace_id is null then
    -- importação do Trello com área escolhida
    new.workspace_id := public.try_uuid(nullif(current_setting('app.import_workspace', true), ''));
  end if;
  if new.workspace_id is null then
    -- sem área informada: usa a área padrão, se a pessoa for membro dela; senão a primeira área dela
    select coalesce(
      (select c.default_workspace from app_config c where c.id = 1 and public.is_ws_member(c.default_workspace)),
      (select m.workspace_id from workspace_members m join workspaces w on w.id = m.workspace_id
        where m.user_id = auth.uid() order by w.name limit 1))
      into new.workspace_id;
    if new.workspace_id is null then
      raise exception 'Você ainda não participa de nenhuma área de trabalho. Peça ao administrador para incluí-lo em uma área.';
    end if;
  end if;
  if auth.uid() is not null
     and (tg_op = 'INSERT' or new.workspace_id is distinct from old.workspace_id)
     and not public.is_ws_member(new.workspace_id) then
    raise exception 'Você só pode colocar quadros em áreas das quais participa';
  end if;
  return new;
end $$;
drop trigger if exists trg_boards_check_workspace on public.boards;
create trigger trg_boards_check_workspace before insert or update of workspace_id on public.boards
  for each row execute function public.boards_check_workspace();

alter table public.boards alter column workspace_id set not null;

-- Quem cria a área vira administrador dela
create or replace function public.workspaces_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.created_by is not null then
    insert into workspace_members (workspace_id, user_id, role, added_by)
    values (new.id, new.created_by, 'admin', new.created_by) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists trg_workspaces_after_insert on public.workspaces;
create trigger trg_workspaces_after_insert after insert on public.workspaces
  for each row execute function public.workspaces_after_insert();

drop trigger if exists trg_workspaces_touch on public.workspaces;
create trigger trg_workspaces_touch before update on public.workspaces
  for each row execute function public.touch_updated_at();

-- Área com quadros não pode ser excluída (mensagem amigável)
create or replace function public.workspaces_before_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from boards where workspace_id = old.id) then
    raise exception 'Esta área ainda tem quadros. Mova ou exclua os quadros antes de excluir a área.';
  end if;
  return old;
end $$;
drop trigger if exists trg_workspaces_before_delete on public.workspaces;
create trigger trg_workspaces_before_delete before delete on public.workspaces
  for each row execute function public.workspaces_before_delete();

-- Usuário aprovado entra automaticamente na área padrão
create or replace function public.profiles_join_default_ws() returns trigger
language plpgsql security definer set search_path = public as $$
declare w uuid;
begin
  if new.status = 'active' and (tg_op = 'INSERT' or old.status is distinct from 'active') then
    select default_workspace into w from app_config where id = 1;
    if w is not null then
      insert into workspace_members (workspace_id, user_id, role, added_by)
      values (w, new.id, 'member', auth.uid()) on conflict do nothing;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_profiles_join_default_ws on public.profiles;
create trigger trg_profiles_join_default_ws after insert or update of status on public.profiles
  for each row execute function public.profiles_join_default_ws();

-- --------------------------------------------------------------------------
-- [E] HISTÓRICO
-- --------------------------------------------------------------------------
-- Histórico do quadro: inclui mudança de área e de visibilidade
create or replace function public.trg_log_boards() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform log_activity(new.id, null, 'board_created', jsonb_build_object('title', new.title));
  elsif tg_op = 'UPDATE' then
    if new.title is distinct from old.title then
      perform log_activity(new.id, null, 'board_renamed', jsonb_build_object('from', old.title, 'to', new.title));
    end if;
    if new.archived is distinct from old.archived then
      perform log_activity(new.id, null, case when new.archived then 'board_archived' else 'board_restored' end, '{}');
    end if;
    if new.visibility is distinct from old.visibility then
      perform log_activity(new.id, null, 'board_visibility', jsonb_build_object('from', old.visibility, 'to', new.visibility));
    end if;
    if new.workspace_id is distinct from old.workspace_id then
      perform log_activity(new.id, null, 'board_workspace', jsonb_build_object(
        'from', (select name from workspaces where id = old.workspace_id),
        'to',   (select name from workspaces where id = new.workspace_id)));
    end if;
  elsif tg_op = 'DELETE' then
    perform log_activity(old.id, null, 'board_deleted', jsonb_build_object('title', old.title));
  end if;
  return coalesce(new, old);
end $$;

-- Histórico de administração: áreas e seus membros
create or replace function public.trg_audit_workspaces() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform log_admin('workspace_created', null, null, jsonb_build_object('name', new.name));
  elsif tg_op = 'UPDATE' and new.name is distinct from old.name then
    perform log_admin('workspace_renamed', null, null, jsonb_build_object('from', old.name, 'to', new.name));
  elsif tg_op = 'DELETE' then
    perform log_admin('workspace_deleted', null, null, jsonb_build_object('name', old.name));
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists trg_audit_workspaces on public.workspaces;
create trigger trg_audit_workspaces after insert or update or delete on public.workspaces
  for each row execute function public.trg_audit_workspaces();

create or replace function public.trg_audit_ws_members() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r  workspace_members := coalesce(new, old);
  nm text := (select name from workspaces where id = r.workspace_id);
  em text := (select email from profiles where id = r.user_id);
begin
  if nm is null then return coalesce(new, old); end if; -- área sendo excluída
  if tg_op = 'INSERT' then
    perform log_admin('workspace_member_added', r.user_id, em,
      jsonb_build_object('name', profile_name(r.user_id), 'workspace', nm, 'role', r.role));
  elsif tg_op = 'UPDATE' and new.role is distinct from old.role then
    perform log_admin('workspace_member_role', r.user_id, em,
      jsonb_build_object('name', profile_name(r.user_id), 'workspace', nm, 'to', new.role));
  elsif tg_op = 'DELETE' then
    perform log_admin('workspace_member_removed', r.user_id, em,
      jsonb_build_object('name', profile_name(r.user_id), 'workspace', nm));
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists trg_audit_ws_members on public.workspace_members;
create trigger trg_audit_ws_members after insert or update or delete on public.workspace_members
  for each row execute function public.trg_audit_ws_members();

-- --------------------------------------------------------------------------
-- [F] FUNÇÕES DA ADMINISTRAÇÃO
-- --------------------------------------------------------------------------
-- Lista de todos os quadros, sem conteúdo (somente administrador do sistema)
drop function if exists public.admin_boards();
create or replace function public.admin_boards()
returns table (id uuid, title text, archived boolean, color text, visibility text,
               workspace_id uuid, workspace text, owners text, members int, is_member boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Somente o administrador do sistema'; end if;
  return query
  select b.id, b.title, b.archived, b.color, b.visibility, b.workspace_id, w.name,
         coalesce((select string_agg(p.full_name, ', ' order by p.full_name)
                     from board_members m join profiles p on p.id = m.user_id
                    where m.board_id = b.id and m.role = 'owner'), ''),
         (select count(*)::int from board_members m where m.board_id = b.id),
         exists (select 1 from board_members m where m.board_id = b.id and m.user_id = auth.uid()),
         b.created_at
    from boards b join workspaces w on w.id = b.workspace_id
   order by w.name, b.title;
end $$;

-- Administrador assume acesso (vira dono) de um quadro; fica registrado
create or replace function public.admin_take_board(p_board uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if not public.is_admin() then raise exception 'Somente o administrador do sistema'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Informe o motivo'; end if;
  select title into t from boards where id = p_board;
  if t is null then raise exception 'Quadro inexistente'; end if;
  insert into board_members (board_id, user_id, role, added_by)
  values (p_board, auth.uid(), 'owner', auth.uid())
  on conflict (board_id, user_id) do update set role = 'owner';
  perform log_admin('board_access_taken', null, null,
    jsonb_build_object('board', t, 'board_id', p_board, 'reason', left(trim(p_reason), 300)));
end $$;

-- Importação do Trello: agora exige área (parâmetro opcional no payload)
--   Mantém a função existente; o quadro importado recebe a área escolhida
--   (ou, sem escolha, a área padrão ou a primeira área do administrador).
drop trigger if exists trg_import_set_workspace on public.boards;
drop function if exists public.import_set_workspace();

create or replace function public.import_board_to(p_workspace uuid, payload jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if p_workspace is not null and not public.is_ws_member(p_workspace) then
    raise exception 'Você só pode importar para áreas das quais participa';
  end if;
  perform set_config('app.import_workspace', coalesce(p_workspace::text, ''), true);
  return public.import_board(payload);
end $$;

-- --------------------------------------------------------------------------
-- [G] SEGURANÇA EM NÍVEL DE LINHA
-- --------------------------------------------------------------------------
alter table public.workspaces        enable row level security;
alter table public.workspace_members enable row level security;

-- Áreas: o nome aparece para quem participa, para o administrador
-- e para quem enxerga algum quadro da área
drop policy if exists ws_select on public.workspaces;
create policy ws_select on public.workspaces for select to authenticated
  using (public.is_admin() or public.is_ws_member(id)
         or exists (select 1 from boards b where b.workspace_id = workspaces.id and public.can_view_board(b.id)));
drop policy if exists ws_insert on public.workspaces;
create policy ws_insert on public.workspaces for insert to authenticated
  with check (public.is_admin() and created_by = auth.uid());
drop policy if exists ws_update on public.workspaces;
create policy ws_update on public.workspaces for update to authenticated
  using (public.can_manage_ws(id)) with check (public.can_manage_ws(id));
drop policy if exists ws_delete on public.workspaces;
create policy ws_delete on public.workspaces for delete to authenticated using (public.is_admin());

drop policy if exists wsm_select on public.workspace_members;
create policy wsm_select on public.workspace_members for select to authenticated
  using (public.is_admin() or public.is_ws_member(workspace_id));
drop policy if exists wsm_insert on public.workspace_members;
create policy wsm_insert on public.workspace_members for insert to authenticated
  with check (public.can_manage_ws(workspace_id));
drop policy if exists wsm_update on public.workspace_members;
create policy wsm_update on public.workspace_members for update to authenticated
  using (public.can_manage_ws(workspace_id)) with check (public.can_manage_ws(workspace_id));
drop policy if exists wsm_delete on public.workspace_members;
create policy wsm_delete on public.workspace_members for delete to authenticated
  using (public.can_manage_ws(workspace_id) or user_id = auth.uid());

-- Quadros: criar exige participar de alguma área (verificado no gatilho)
drop policy if exists boards_select on public.boards;
create policy boards_select on public.boards for select to authenticated
  using (public.can_view_board(id) or (created_by = auth.uid() and public.is_active_user()));

-- Comentários: só membros do quadro (visitantes apenas leem)
drop policy if exists comments_insert on public.comments;
create policy comments_insert on public.comments for insert to authenticated
  with check (public.can_participate_board(board_id) and user_id = auth.uid());
drop policy if exists comments_update on public.comments;
create policy comments_update on public.comments for update to authenticated
  using (user_id = auth.uid() and public.can_participate_board(board_id)) with check (user_id = auth.uid());
drop policy if exists comments_delete on public.comments;
create policy comments_delete on public.comments for delete to authenticated
  using ((user_id = auth.uid() and public.can_participate_board(board_id)) or public.can_manage_board(board_id));

-- Cartão por template: só membros do quadro (inclui leitor), não visitantes
create or replace function public.create_card_from_template(p_list uuid, p_template uuid, p_title text, p_answers jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_board uuid;
  v_card  uuid;
  tpl     card_templates;
  r       jsonb;
begin
  select board_id into v_board from lists where id = p_list and not archived;
  if v_board is null then raise exception 'Lista inválida'; end if;
  if not public.can_participate_board(v_board) then raise exception 'Somente membros do quadro podem criar cartões'; end if;
  if exists (select 1 from boards where id = v_board and archived) then raise exception 'Este quadro está arquivado'; end if;

  select * into tpl from card_templates where id = p_template and active;
  if tpl.id is null or not (tpl.all_boards or v_board = any(tpl.boards)) then
    raise exception 'Este template não está disponível neste quadro';
  end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Informe o título do cartão'; end if;

  r := public.template_build_answers(tpl.fields, coalesce(p_answers, '{}'::jsonb));

  insert into cards (board_id, list_id, title, position, due_date, template_id, template_name, form_data, created_by)
  values (v_board, p_list, left(regexp_replace(trim(p_title), '\s+', ' ', 'g'), 300),
          (select coalesce(max(position), 0) + 1000 from cards where list_id = p_list),
          case when r->>'due_hours' is not null then now() + ((r->>'due_hours')::numeric * interval '1 hour') end,
          tpl.id, tpl.name, r->'data', auth.uid())
  returning id into v_card;

  perform public.apply_priority_tag(v_card, v_board, tpl.fields, r->'tag');
  return v_card;
end $$;

-- Tempo real para a lista de áreas
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.workspace_members; exception when others then null; end;
  end if;
end $$;
