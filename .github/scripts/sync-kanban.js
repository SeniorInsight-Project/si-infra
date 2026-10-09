// Sincroniza o quadro único da organização.
// - Cria o projeto (se não existir) com as colunas padrão.
// - Adiciona as issues abertas com a label do quadro (padrão: mvp) de todos os repositórios.
// - Itens novos herdam a coluna que tinham nos quadros antigos; senão, HUs entram em "Backlog"
//   e o resto (fundação) em "A fazer".
// - Itens que já estão no quadro não são movidos (respeita o que o time mudou), exceto os
//   que estão sem coluna, que recebem a coluna padrão.
// - Limpeza: issue fechada como concluída vai para "Concluído"; issue fechada como
//   duplicada ou não planejada, issue sem a label e PR saem do quadro.

const COLUNAS = ['Backlog', 'A fazer', 'Em andamento', 'Em revisão', 'Concluído'];
const CORES = { Backlog: 'GRAY', 'A fazer': 'BLUE', 'Em andamento': 'YELLOW', 'Em revisão': 'PURPLE', Concluído: 'GREEN' };

function colunaEquivalente(nome) {
  if (!nome) return null;
  const n = nome.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
  if (/done|conclu|feito|finaliz|fechad/.test(n)) return 'Concluído';
  if (/review|revis|teste|qa|homolog/.test(n)) return 'Em revisão';
  if (/progress|andamento|doing|fazendo/.test(n)) return 'Em andamento';
  if (/todo|to do|a fazer|ready|pronto|sprint/.test(n)) return 'A fazer';
  return 'Backlog';
}

module.exports = async ({ github, core }) => {
  const org = process.env.ORG;
  const titulo = process.env.PROJECT_TITLE;
  const fecharAntigos = process.env.CLOSE_OLD === 'true';
  const label = process.env.BOARD_LABEL || 'mvp';
  const reorganizar = process.env.REORGANIZE === 'true';

  // 1. Organização e projetos existentes
  const { organization } = await github.graphql(
    `query($org:String!){ organization(login:$org){ id
       projectsV2(first:50){ nodes{ id number title closed } } } }`,
    { org });
  const projetos = organization.projectsV2.nodes;
  let projeto = projetos.find(p => p.title === titulo);

  if (!projeto) {
    const r = await github.graphql(
      `mutation($owner:ID!,$title:String!){ createProjectV2(input:{ownerId:$owner,title:$title}){ projectV2{ id number title closed } } }`,
      { owner: organization.id, title: titulo });
    projeto = r.createProjectV2.projectV2;
    core.info(`Projeto criado: #${projeto.number}`);
  } else if (projeto.closed) {
    await github.graphql(`mutation($id:ID!){ updateProjectV2(input:{projectId:$id,closed:false}){ projectV2{ id } } }`, { id: projeto.id });
  }

  // 2. Campo Status com as colunas padrão
  const campos = await github.graphql(
    `query($id:ID!){ node(id:$id){ ... on ProjectV2 { field(name:"Status"){ ... on ProjectV2SingleSelectField { id options{ id name } } } } } }`,
    { id: projeto.id });
  let status = campos.node.field;
  const nomesAtuais = status.options.map(o => o.name);
  if (nomesAtuais.join('|') !== COLUNAS.join('|')) {
    // Só acontece na criação: trocar as opções zera o Status dos itens.
    const r = await github.graphql(
      `mutation($f:ID!,$opts:[ProjectV2SingleSelectFieldOptionInput!]){
         updateProjectV2Field(input:{fieldId:$f,singleSelectOptions:$opts}){
           projectV2Field{ ... on ProjectV2SingleSelectField { id options{ id name } } } } }`,
      { f: status.id, opts: COLUNAS.map(name => ({ name, color: CORES[name], description: '' })) });
    status = r.updateProjectV2Field.projectV2Field;
  }
  const opcao = Object.fromEntries(status.options.map(o => [o.name, o.id]));

  // 3. Itens de um projeto (id do conteúdo -> item)
  async function itensDe(projectId) {
    const mapa = new Map();
    let after = null;
    do {
      const r = await github.graphql(
        `query($id:ID!,$after:String){ node(id:$id){ ... on ProjectV2 { items(first:100,after:$after){
           pageInfo{ hasNextPage endCursor }
           nodes{ id
             content{ __typename ... on Issue{ id number title repository{ name } state stateReason labels(first:30){ nodes{ name } } } ... on PullRequest{ id } }
             fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } }`,
        { id: projectId, after });
      const pg = r.node.items;
      for (const it of pg.nodes) {
        if (!it.content?.id) continue;
        mapa.set(it.content.id, {
          itemId: it.id, tipo: it.content.__typename, estado: it.content.state, motivo: it.content.stateReason,
          labels: (it.content.labels?.nodes ?? []).map(l => l.name), coluna: it.fieldValueByName?.name ?? null,
          titulo: it.content.title ?? '',
          nome: it.content.repository ? `${it.content.repository.name}#${it.content.number} ${it.content.title}` : it.content.id,
        });
      }
      after = pg.pageInfo.hasNextPage ? pg.pageInfo.endCursor : null;
    } while (after);
    return mapa;
  }

  const noQuadro = await itensDe(projeto.id);
  const antigos = projetos.filter(p => p.id !== projeto.id && !p.closed);
  core.info(`Quadros da organização: ${projetos.map(p => `#${p.number} ${p.title} (${p.closed ? 'fechado' : 'aberto'})`).join('; ')}`);
  const colunaAntiga = new Map();
  for (const p of antigos) {
    for (const [id, it] of await itensDe(p.id)) {
      if (!colunaAntiga.has(id) || it.coluna) colunaAntiga.set(id, colunaEquivalente(it.coluna));
    }
  }

  // 4. Limpeza do quadro
  const moverPara = (itemId, coluna) => github.graphql(
    `mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){ updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){ projectV2Item{ id } } }`,
    { p: projeto.id, i: itemId, f: status.id, o: opcao[coluna] });

  // Coluna de quem entra sem histórico: HUs e suas tarefas em "Backlog", fundação em "A fazer"
  const colunaPadrao = t => t.startsWith('HU-') ? 'Backlog' : 'A fazer';

  let removidos = 0;
  for (const [id, it] of noQuadro) {
    const fechadaConcluida = it.tipo === 'Issue' && it.estado === 'CLOSED' && it.motivo === 'COMPLETED';
    const sai = it.tipo !== 'Issue'
      || (it.estado === 'CLOSED' && !fechadaConcluida)
      || (it.estado === 'OPEN' && !it.labels.includes(label));
    if (sai) {
      await github.graphql(`mutation($p:ID!,$i:ID!){ deleteProjectV2Item(input:{projectId:$p,itemId:$i}){ deletedItemId } }`,
        { p: projeto.id, i: it.itemId });
      noQuadro.delete(id);
      removidos++;
    } else if (fechadaConcluida && it.coluna !== 'Concluído') {
      await moverPara(it.itemId, 'Concluído');
    } else if (it.estado === 'OPEN' && !it.coluna) {
      // Entrou sozinha no quadro (ex.: sub-issue adicionada pelo GitHub) e ficou sem coluna
      await moverPara(it.itemId, colunaPadrao(it.titulo));
    }
  }
  core.info(`Itens removidos nesta execução: ${removidos}`);

  // Reorganização opcional: fundação (título sem "HU-") em "A fazer", HUs e suas tarefas em "Backlog"
  if (reorganizar) {
    for (const it of noQuadro.values()) {
      if (it.estado !== 'OPEN') continue;
      const coluna = colunaPadrao(it.titulo);
      if (it.coluna !== coluna) await moverPara(it.itemId, coluna);
    }
  }

  // 5. Repositórios e issues abertas com a label
  const repos = await github.paginate(github.rest.repos.listForOrg, { org, per_page: 100 });
  let adicionados = 0;
  for (const repo of repos.filter(r => !r.archived)) {
    try {
      await github.graphql(`mutation($p:ID!,$r:ID!){ linkProjectV2ToRepository(input:{projectId:$p,repositoryId:$r}){ repository{ id } } }`,
        { p: projeto.id, r: repo.node_id });
    } catch (e) { /* já vinculado */ }

    {
      let after = null;
      do {
        const r = await github.graphql(
          `query($o:String!,$n:String!,$l:String!,$after:String){ repository(owner:$o,name:$n){
             issues(states:OPEN,labels:[$l],first:100,after:$after){ pageInfo{ hasNextPage endCursor } nodes{ id number title } } } }`,
          { o: org, n: repo.name, l: label, after });
        const pg = r.repository.issues;
        for (const item of pg.nodes) {
          if (noQuadro.has(item.id)) continue;
          const add = await github.graphql(
            `mutation($p:ID!,$c:ID!){ addProjectV2ItemById(input:{projectId:$p,contentId:$c}){ item{ id } } }`,
            { p: projeto.id, c: item.id });
          const coluna = colunaAntiga.get(item.id) ?? colunaPadrao(item.title);
          await moverPara(add.addProjectV2ItemById.item.id, coluna);
          noQuadro.set(item.id, { coluna });
          adicionados++;
        }
        after = pg.pageInfo.hasNextPage ? pg.pageInfo.endCursor : null;
      } while (after);
    }
  }
  core.info(`Itens adicionados nesta execução: ${adicionados}`);

  // Lista final do quadro no log, por coluna
  const final = await itensDe(projeto.id);
  for (const coluna of [...COLUNAS, null]) {
    const nomes = [...final.values()].filter(it => (it.coluna ?? null) === coluna).map(it => it.nome).sort();
    if (nomes.length) core.info(`\n[${coluna ?? 'Sem coluna'}] ${nomes.length} itens\n  ` + nomes.join('\n  '));
  }

  // 6. Fechar os quadros antigos (opcional; reversível em Settings do projeto)
  if (fecharAntigos) {
    for (const p of antigos) {
      await github.graphql(`mutation($id:ID!){ updateProjectV2(input:{projectId:$id,closed:true}){ projectV2{ id } } }`, { id: p.id });
      core.info(`Quadro fechado: #${p.number} ${p.title}`);
    }
  }
  core.summary.addRaw(`Quadro: https://github.com/orgs/${org}/projects/${projeto.number} — ${adicionados} itens novos, ${removidos} removidos`).write();
};
