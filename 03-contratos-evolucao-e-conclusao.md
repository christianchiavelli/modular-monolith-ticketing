# 11. Contratos de Serviço

Contratos são o acordo formal e versionável entre produtor e consumidor de uma capacidade. Mesmo dentro de um monólito modular, tratar contratos como cidadãos de primeira classe é o que torna a extração futura barata, porque sem contratos explícitos o "monólito modular" degenera no antipadrão *modulith de fachada*, em que módulos se conhecem internamente em demasia.

## 11.1. Princípios Adotados

1. **Consumer-Driven Contracts (CDC), mesmo internamente.** Cada chamada inter-módulo é coberta por teste de contrato que falha no CI se o produtor mudar de forma incompatível. Aplico a mesma disciplina entre módulos hoje que aplicaria entre serviços amanhã.
2. **Contratos versionados explicitamente.** APIs HTTP usam *URI versioning* (`/api/v1/...`), não por dogma, mas porque é a forma mais simples e auditável de roteamento para um sistema com ciclo de release curto e único squad. Header versioning seria preferível em ecossistema multi-cliente legado; não é o nosso caso.
3. **Eventos versionados por sufixo no nome do evento.** `Reserva.Confirmada.v1`, `Reserva.Confirmada.v2`. Coexistência durante a janela de migração; o produtor pode emitir ambos por um período.
4. **Evolução backward-compatible por padrão.** Adicionar campos opcionais é OK; remover ou renomear exige nova versão.
5. **Governança leve.** Não há comitê de arquitetura aprovando cada endpoint. Há um *style guide* curto, revisão de PR obrigatória para mudanças em contratos, e o linter detecta breaking changes.

## 11.2. APIs HTTP Principais (especificação resumida em estilo OpenAPI)

### 11.2.1. Catálogo

```yaml
GET /api/v1/eventos
  summary: Lista eventos disponíveis
  query: { page, pageSize, cidade?, dataInicio?, dataFim? }
  responses:
    200: PagedResult<EventoResumo>

GET /api/v1/eventos/{eventoId}
  responses:
    200: EventoDetalhe
    404: Problem

GET /api/v1/eventos/{eventoId}/mapa-assentos
  summary: Retorna o mapa de assentos com disponibilidade
  cacheControl: public, max-age=5
  responses:
    200: MapaAssentos    # leitura do cache; eventual staleness <= 5s
```

### 11.2.2. Reserva

```yaml
POST /api/v1/reservas
  summary: Cria uma reserva temporária (lock de assentos)
  headers:
    Idempotency-Key: required (UUID v4; TTL 24h)
    X-Admission-Token: required (token da waiting room)
  body:
    eventoId: UUID
    assentos: [UUID]    # 1..6
  responses:
    201:
      body: { reservaId, expiresAt, assentos:[{id, setor, preco}] }
    409: ASSENTO_INDISPONIVEL    # ao menos um assento já reservado
    410: TOKEN_ADMISSAO_EXPIRADO
    429: RATE_LIMITED

GET /api/v1/reservas/{reservaId}
  responses:
    200: Reserva

DELETE /api/v1/reservas/{reservaId}
  summary: Cancela reserva pendente (libera assentos)
  responses:
    204
    409: RESERVA_JA_CONFIRMADA
```

### 11.2.3. Pagamento

```yaml
POST /api/v1/pagamentos
  summary: Inicia ordem de pagamento; retorna URL de redirect para Gateway
  headers:
    Idempotency-Key: required
  body:
    reservaId: UUID
    metodo: enum [CARTAO, PIX, BOLETO]
  responses:
    201: { ordemId, redirectUrl, expiresAt }
    409: RESERVA_EXPIRADA | RESERVA_NAO_ENCONTRADA

POST /api/v1/pagamentos/webhook
  summary: Webhook chamado pelo Gateway (autenticação por HMAC)
  security: { hmacSignature: required, headerName: X-Gateway-Signature }
  body: GatewayCallbackEnvelope
  responses:
    200    # idempotente; mesma chamada repetida não duplica efeito
```

### 11.2.4. Ingresso

```yaml
GET /api/v1/ingressos/meus
  summary: Lista ingressos do usuário autenticado
  responses:
    200: PagedResult<Ingresso>

GET /api/v1/ingressos/{ingressoId}/qrcode
  summary: Retorna QR Code (PNG) assinado do ingresso
  responses:
    200: image/png
    403: NAO_PROPRIETARIO
```

### 11.2.5. Métricas (produtor)

```yaml
GET /api/v1/produtores/eventos/{eventoId}/metricas
  summary: Métricas agregadas para o produtor (staleness ~30s)
  security: { role: PRODUTOR_EVENTO }
  responses:
    200:
      body:
        ingressosVendidos: int
        receitaBruta: Money
        taxaConversao: number   # reservas confirmadas / reservas criadas
        capacidadeUtilizada: number  # 0..1
        timestamp: ISODateTime  # quando foi última atualização da projeção
```

## 11.3. Contratos de Eventos

Cada evento publicado tem schema explícito, versionado e registrado:

```json
{
  "eventType": "Reserva.Confirmada.v1",
  "eventId": "uuid",
  "occurredAt": "ISO-8601",
  "correlationId": "uuid",
  "causationId": "uuid",
  "tenantId": "string",
  "data": {
    "reservaId": "uuid",
    "eventoId": "uuid",
    "usuarioId": "uuid",
    "assentos": [{ "assentoId": "uuid", "preco": { "valor": 250.00, "moeda": "BRL" } }],
    "confirmadaEm": "ISO-8601"
  }
}
```

Convenções:

- **`correlationId`** propagado por todo o fluxo, presente em logs, traces e eventos.
- **`causationId`** rastreia qual evento causou este: fundamental para depurar coreografias.
- Schemas registrados em um *schema registry* (mesmo que arquivo versionado em repositório no início; serviço dedicado quando justificar).
- Consumidores fazem *parsing tolerante* (ignorar campos desconhecidos), preservando *forward compatibility*.

## 11.4. Governança Operacional dos Contratos

- **Mudança em contrato HTTP**: PR obrigatório com label `contract-change`, exige aprovação adicional.
- **Mudança incompatível**: nova versão (`v2`) coexistindo com `v1` por mínimo uma sprint; clientes migrados; só então `v1` é removida.
- **Testes de contrato** rodam em CI; quebra de contrato é red build.
- **API changelog** mantido em `CHANGELOG.md` por módulo.

## 11.5. Preparação para Extração

Os contratos internos foram desenhados para que possam ser substituídos por HTTP sem mudar o consumidor. Concretamente:

- A API de aplicação do módulo Reserva é uma interface (`IReservaApi`) cuja implementação atual é in-process; no dia da extração, a implementação vira um adapter HTTP. Nenhum consumidor muda.
- A publicação de eventos já passa por broker, então a extração não muda o caminho de eventos.
- A única dependência transacional (Pagamento confirmando Reserva dentro de uma transação ACID) é o ponto que vira **Saga** na extração; já está documentado em §12 e §16 como tal.

---

# 12. Consistência Forte vs Consistência Eventual

A decisão de onde aplicar cada modelo de consistência é uma das mais consequentes em qualquer arquitetura. O critério aqui é simples e vem direto dos drivers: consistência forte onde o domínio tem regra de unicidade; consistência eventual onde a leitura tolera alguma defasagem.

## 12.1. Mapa de Consistência por Subdomínio

O caminho crítico de compra (Reserva → Pagamento → Ingresso) usa consistência forte, com ACID local. Não há janela observável de inconsistência nesse fluxo, o que é inegociável dado o Driver 1.

Já o mapa de assentos é eventual, com staleness de até 5 segundos: mostrar disponibilidade quase em tempo real é suficiente, porque a confirmação real só acontece no commit da reserva, que valida unicidade no banco. O mapa serve apenas para reduzir a frustração de alguém tentando um assento já tomado.

Notificações são completamente eventuais; receber o e-mail 30 segundos depois é aceitável. Receber duas vezes é gerenciável via idempotência no consumidor. O único caso ruim é receber zero vezes, e para isso tem DLQ com alarme. As métricas para o produtor têm staleness de até 30 segundos, o que é mais que suficiente para quem está olhando dashboards em granularidade de minutos. Auditoria é eventual com persistência garantida: o outbox assegura at-least-once, e o consumidor é idempotente por `event_id`.

## 12.2. Por que **não** Saga no Caminho Crítico (hoje)

A literatura sobre microsserviços trata Saga como o padrão para transações distribuídas. O ponto aqui é que Saga é a resposta certa para um problema que este sistema, na configuração atual, simplesmente não tem ainda.

Saga implica:

- Inconsistência observável em janela (assento aparece como confirmado em um serviço enquanto pagamento ainda não confirmou no outro).
- Compensações explícitas: se pagamento falha após confirmação de reserva, é preciso emitir uma compensação que reverte a reserva.
- Coordenação, seja por orquestrador central ou coreografia complexa.
- Idempotência rigorosa em cada passo.
- Observabilidade especializada para rastrear o estado da Saga.

O monólito modular permite uma única transação ACID local que faz `confirma reserva → registra pagamento autorizado → emite ingresso` atomicamente. Zero janela de inconsistência, zero compensação. Essa é a vantagem concreta que justifica a escolha.

Confesso que esse foi o ponto que mais discuti comigo mesmo ao escrever este documento. Existe uma pressão real — que já vi acontecer em outros projetos — de implementar Saga "para estar preparado". Mas o custo de complexidade é alto e o benefício só aparece quando os serviços forem de fato separados. Adiar Saga não é ingenuidade; é uma decisão de não pagar o custo hoje por um benefício que só vai existir amanhã.

## 12.3. Como Saga entra como Evolução Futura (Quando Extrair Reserva)

Quando o módulo Reserva for extraído como microsserviço (gatilhos em §16), a transação local será substituída por uma **Saga orquestrada** com a seguinte forma:

```mermaid
sequenceDiagram
    autonumber
    participant U as Comprador
    participant O as Orquestrador (Pagamento)
    participant R as Serviço Reserva
    participant G as Gateway
    participant I as Serviço Ingresso

    U->>O: Inicia pagamento (reservaId)
    O->>R: Marca reserva como PAGAMENTO_EM_CURSO (lock lógico)
    R-->>O: OK
    O->>G: Autoriza pagamento
    alt Autorização OK
        G-->>O: Autorizado
        O->>R: Confirma reserva (HELD → CONFIRMED)
        R-->>O: OK
        O->>I: Emite ingresso
        I-->>O: Ingresso emitido
        O-->>U: Sucesso
    else Falha de autorização
        G-->>O: Recusado
        O->>R: COMPENSA (PAGAMENTO_EM_CURSO → HELD)
        R-->>O: OK
        O-->>U: Falha (recusado)
    else Falha pós-autorização (ex: emissão falha)
        O->>G: Estorna (compensação financeira)
        O->>R: COMPENSA (CONFIRMED → HELD)
        O-->>U: Erro; reembolso em curso
    end
```

Pontos a observar:

- A Saga é **orquestrada** (pelo módulo/serviço Pagamento), não coreografada. A escolha é por rastreabilidade em fluxos transacionais; coreografia seria pesadelo de debug aqui.
- Cada passo é **idempotente** (chave de idempotência por `sagaId` + `stepId`).
- O estado da Saga é **persistido** em cada transição (event sourcing parcial no Pagamento).
- Compensações são **explícitas**, não inferidas.

## 12.4. Outbox como Ponte entre Forte e Eventual

O outbox pattern (já citado em ADR-004) é a ponte técnica que permite os dois mundos coexistirem. A transação ACID local garante consistência forte interna, e a inclusão de eventos na mesma transação garante que "se commitou, vai propagar". O relay assíncrono publica para o broker, ponto a partir do qual a consistência se torna eventual.

O resultado é que o sistema é fortemente consistente internamente e eventualmente consistente externamente, sem que o usuário veja inconsistência no caminho crítico de compra.

---

# 13. Propriedade dos Dados

A propriedade clara dos dados é o principal mecanismo de prevenção de acoplamento entre módulos. Sem isso, qualquer separação em camadas vira fachada em pouco tempo. Quer dizer, mais precisamente: você cria nomes bonitos para os módulos, mas o código acessa o banco de qualquer jeito e o "monólito modular" vira um monólito tradicional com nomes fancy.

## 13.1. Regra Geral

Cada agregado tem um único módulo dono. O dono é o único que escreve. Todos os outros leem por API de aplicação ou por evento.

## 13.2. Tabela de Propriedade

| Agregado | Módulo dono | Quem mais pode ler? | Como? |
|---|---|---|---|
| `Evento`, `Setor`, `Assento` | Catálogo | Reserva, Métricas | API de aplicação (`ICatalogoApi`) ou evento `Catalogo.EventoPublicado.v1` |
| `Reserva` | Reserva | Pagamento, Ingresso, Métricas | API de aplicação (`IReservaApi`) ou evento `Reserva.Confirmada.v1` |
| `OrdemDePagamento` | Pagamento | Ingresso, Métricas | API de aplicação (`IPagamentoApi`) ou evento `Pagamento.Autorizado.v1` |
| `Ingresso` | Ingresso | Notificação, Métricas, Comprador (via API HTTP) | Evento `Ingresso.Emitido.v1` |
| `EnvioDeNotificacao` | Notificação | — | (interno) |
| Projeções de Métricas | Métricas (CQRS) | Produtor (via API HTTP) | — |

## 13.3. Padrões de Leitura Cross-Module

### Padrão A — Projeção Local por Evento (preferencial)

Quando um módulo precisa frequentemente de dados de outro, ele materializa uma projeção local alimentada por eventos. O módulo Métricas, por exemplo, mantém uma tabela `metricas.evento_vendas` alimentada por `Reserva.Confirmada.v1` e `Pagamento.Autorizado.v1`. Lê do próprio schema, sem chamar Catálogo ou Pagamento em runtime. O acoplamento é mínimo, a leitura é rápida, e a consistência eventual é aceitável nesse contexto. A desvantagem é duplicação controlada de dados e a necessidade de tratamento de eventos perdidos.

### Padrão B — API de Aplicação In-Process

Quando a leitura precisa ser fresca e síncrona (caso típico: Reserva consultando o Catálogo para validar que o evento está aberto para vendas no momento da reserva). Os dados são sempre frescos e a transação ACID funciona normalmente. A contrapartida é um acoplamento maior entre módulos; se algum dia extrair, essa chamada vira HTTP, e daí a importância de a interface já estar bem desenhada desde o início.

### Padrão C — Cache para Disponibilidade

O mapa de assentos é um caso especial: leitura altíssima, escrita por evento. Mantemos uma cópia no Redis, invalidada e atualizada via eventos `Reserva.Criada.v1` e `Reserva.Expirada.v1`. Nunca é fonte de verdade. É só otimização de leitura.

## 13.4. Antipattern Explicitamente Proibido

- **Cross-schema JOIN**: nenhum módulo faz `SELECT ... FROM reserva.X JOIN catalogo.Y`. Isso é detectado por linter SQL e por revisão.
- **Leitura direta do schema alheio em código**: repositórios são proibidos de tocar tabelas que não sejam do seu schema.
- **Foreign keys cross-schema**: são evitadas. Integridade referencial cross-module é responsabilidade lógica do dono, não constraint de banco.

## 13.5. Implicação para Extração Futura

Quando Reserva for extraído como serviço dedicado, o schema `reserva` migra inteiro para o novo serviço (com sua própria base, eventualmente). A interface `IReservaApi` ganha implementação HTTP, então os consumidores não precisam ser refatorados. Projeções locais que dependiam de eventos `Reserva.*` continuam funcionando sem mudança. A transação ACID Reserva↔Pagamento vira Saga (§12.3), esse é o único ponto que exige reestruturação significativa.

A extração é cara, mas previsível e localizada, exatamente porque a propriedade de dados foi tratada com seriedade desde o começo.

---

# 14. Impacto na Efetividade dos Times

Arquitetura existe para servir times tanto quanto para servir o sistema. Uma arquitetura tecnicamente brilhante mas que sufoca o time é uma arquitetura ruim. Isso parece óbvio, mas é fácil esquecer no meio de discussões sobre padrões e frameworks. E a Lei de Conway confirma isso de um ângulo diferente: a estrutura técnica reflete e molda a estrutura humana, então ignorar o time ao desenhar a arquitetura é uma contradição prática.

## 14.1. Como a Arquitetura Habilita o Time

### 14.1.1. Paralelismo de Trabalho

Os bounded contexts permitem que subgrupos do squad trabalhem em paralelo sem se atrapalharem. Uma pessoa no caminho de Reserva, outra em Notificações, outra em Métricas, sem conflito em código ou deploy. Como todos vivem no mesmo repositório, a revisão cruzada continua trivial. Conflitos de merge ficam confinados a fronteiras de módulo (raros), não atravessam todo o código.

### 14.1.2. Contratos Internos Claros

Mesmo dentro de um único squad, ter o contrato escrito elimina discussões sobre como invocar o módulo Reserva. Está documentado. Isso reduz interrupções e diminui o tempo de onboarding de quem entra no time.

### 14.1.3. Evolução Independente

- O módulo Notificação pode mudar seu provedor de e-mail sem que o resto do sistema saiba.
- O módulo Pagamento pode trocar de Gateway com uma feature flag.
- O módulo Métricas pode reescrever sua projeção (incluindo backfill por replay de eventos) sem afetar a compra.

### 14.1.4. Sustentabilidade da Engenharia

Na prática, o que mais me preocupa em projetos de longa duração é a sustentabilidade, não a performance inicial. É fácil fazer um sistema ir rápido no começo. O difícil é manter velocidade depois de um ano, quando o código cresceu e o time rodou. A arquitetura aqui tenta incentivar as práticas que sustentam isso.

Testes unitários ficam naturais porque o domínio está isolado de I/O. Não tem o "preciso de banco pra rodar o teste" que mata a produtividade. Testes de integração têm suíte própria por módulo, com testcontainers para banco real. O CI roda tudo em paralelo por módulo, em torno de 10 minutos. Refatoração é mais segura porque as fronteiras claras e a análise estática detectam regressão arquitetural antes de chegar em produção. E a observabilidade com OpenTelemetry é parte da plataforma, não um custo extra que cada módulo precisa resolver sozinho.

## 14.2. Lei de Conway Aplicada Conscientemente

Com um único squad, faz sentido ter um deployable, um backlog, um pipeline. Simples assim.

Se um dia tivermos três squads (Compra, Notificações, Plataforma de Dados), a arquitetura está pronta para essa divisão:

- Squad de Compra cuidando dos módulos Catálogo, Reserva, Pagamento e Ingresso (eventualmente extraindo Reserva).
- Squad de Notificações com o módulo Notificação (candidato natural a extração).
- Squad de Plataforma com Métricas, Outbox e Observabilidade.

A arquitetura não impede essa evolução. Ela a prepara.

## 14.3. Riscos Organizacionais Mitigados

Engenheiro novo que se perde no monólito vai ser ajudado pelas fronteiras de módulo claras, pelos `README.md` por módulo e pelos ADRs. O "esse código está acoplado a tudo" é bloqueado pelo ADP no CI, impossível mergear cíclico. "Não sei onde isso vive" é resolvido pela convenção de namespace por bounded context. "Não consigo testar isso sem subir tudo" não acontece porque o domínio é puro, testável isolado, e integração usa testcontainers. Conflito de prioridades entre módulos é tratado com backlog único e ownership explícito.

---

# 15. Liderança Técnica e Negociação de Requisitos

Arquiteto que só desenha caixinhas falha em metade do papel. A outra metade é comunicar, negociar e proteger a arquitetura ao longo do tempo, com stakeholders técnicos e não-técnicos. Essa parte não está em nenhum livro de arquitetura do jeito que deveria estar.

## 15.1. Comunicação por Audiência

Para produto e negócio, o que importa são os drivers, os trade-offs principais em linguagem de negócio (sem "Saga", sem "CAP theorem") e o roadmap de evolução. Diagrama C4 nível 1 mais tabela de drivers costuma ser suficiente. Para o squad de engenharia, os ADRs no repositório, padrões internos, regras de fronteira e contratos de eventos, completados por sessões técnicas e pareamento. Para liderança técnica e CTO, um one-pager executivo com os riscos arquiteturais, os gatilhos de evolução e o custo total. Para SRE e operações, SLOs, runbooks e os pontos de falha conhecidos, com documentação operacional e game days. Para stakeholders externos como produtores e parceiros, só os contratos de API e o SLA público.

## 15.2. Negociação de Requisitos — Padrões Recorrentes

### Caso 1 — "Por que tem fila? Tira a fila."

É produto, em reunião pós-lançamento, vendo NPS de fila. A fila é o que permite o sistema sobreviver ao pico; sem ela, o sistema cai e ninguém compra. A negociação passa por quantificar o trade-off em termos do produto: sem fila, 100% dos usuários têm experiência ruim por 5 minutos (sistema fora). Com fila, 80% esperam em média 90 segundos e completam a compra. É possível reduzir a fila aumentando capacidade do banco, mas o custo é X/mês. A decisão volta a ser do produto, mas com trade-off explícito na mesa.

### Caso 2 — "A indústria está toda em microsserviços. Por que não nós?"

Esse argumento vai aparecer em algum momento. A resposta é: microsserviços resolvem problemas que ainda não temos e impõem custos que não podemos pagar agora. ADR-001 documenta isso por escrito, e convido a leitura da avaliação comparativa (§8) e dos gatilhos de evolução (§16). Não é "nunca microsserviços", é "ainda não".

Tenho uma preferência declarada por monólito modular, em parte por experiência própria: já vi mais sistemas sofrerem com microsserviços prematuros do que com monólitos disciplinados. Quando você está num time pequeno tentando manter 12 serviços em produção, cada um com seu próprio banco e pipeline, o custo operacional corrói a produtividade de um jeito que é difícil de prever antes de acontecer.

### Caso 3 — "Notificações estão atrasando 30 segundos, é inaceitável."

Notificações são eventualmente consistentes por design. 30 segundos pode ser otimizado, mas exigir sincronicidade quebra o caminho crítico. O primeiro passo é investigar: o atraso é "design" (consistência eventual aceitável) ou "regressão" (lag de broker, worker travado, throttling do provedor)? Se for design, educar o stakeholder com expectativa explícita ("seu e-mail chega em até 60s"). Se for regressão, é incidente.

### Caso 4 — "Vamos adicionar um relatório que une todos os módulos."

Produto pedindo dashboard avançado. Não fazer JOIN cross-schema (ADR-005). A solução é via projeção em Métricas: é possível, é adicionar campos à projeção. Custo de desenvolvimento: X dias. Latência: em torno de 30 segundos (consistência eventual, OK para dashboard). Sair disso seria cair em antipattern documentado.

## 15.3. Princípios de Liderança Técnica Adotados

Alguns princípios que guiam minha abordagem aqui:

- **Decisões reversíveis vs irreversíveis**: tratar com pesos diferentes. Adotar microsserviços é praticamente irreversível na prática porque o custo de voltar atrás é altíssimo. Adicionar um campo em evento é reversível. O peso da decisão precisa ser proporcional à irreversibilidade.
- **Strong opinions, loosely held**: defender os ADRs com rigor, mas estar pronto para revisá-los diante de dados concretos.
- **Architect alongside, not above**: pareamento técnico regular com os engenheiros do squad. Arquiteto que perde contato com o código vira só burocracia.
- **Documentar o porquê, não o como**: ADRs respondem "por que decidimos isso", não "como implementar". O código já mostra o como.
- **Make the right thing easy**: a plataforma cross-cutting torna o caminho correto (outbox, idempotência, observabilidade) o caminho mais fácil de seguir.

---

# 16. Trade-offs Residuais, Riscos e Roadmap de Evolução

Toda arquitetura carrega dívidas conscientes. Documentá-las é o que evita que se tornem dívidas inconscientes, que são as perigosas.

## 16.1. Trade-offs Residuais Aceitos

Sem escalabilidade granular por módulo: o custo de microsserviços excede o benefício atual. Quando (e se) o banco de Reserva saturar, extrai-se o módulo. O RTO de 15 minutos em vez de menos de 1 minuto é uma escolha consciente: multi-região custa muito e o RTO atual é suficiente para o contexto, podendo ser revisado se aparecer requisito regulatório ou de mercado. Notificações com até 60 segundos de delay são aceitáveis por design, e isso provavelmente não muda. O cluster relacional como SPOF lógico é mitigado por Multi-AZ; um segundo cluster seria overkill hoje. Chaos engineering institucionalizado fica para quando o time crescer ou a maturidade exigir; game days trimestrais bastam por ora.

## 16.2. Riscos Arquiteturais

| Risco | Probabilidade | Impacto | Mitigação |
|---|---|---|---|
| Banco satura em pico maior que o projetado | Média | Alto | Admissão controla vazão a montante; alarmes de p95; runbook de scale-up |
| Broker indisponível por janela longa | Baixa | Médio | Outbox segura mensagens; consumidores idempotentes lidam com retomada |
| Provedor de Waiting Room cair | Baixa | Alto | Fallback degradado (rate limit estrito + "venda momentaneamente indisponível") |
| Gateway de Pagamento lento | Alta | Médio | Circuit breaker; comunicação assíncrona via webhook idempotente; UX de "estamos processando" |
| Schema de evento muda incompatível por engano | Média | Médio | Contract tests bloqueiam; versionamento explícito |
| Módulo viola fronteira (cross-schema, ciclo) | Baixa | Alto (longo prazo) | Lint + revisão + ADP em CI |
| Equipe trata "monólito modular" como "monólito" sem disciplina | Média | Alto | ADRs como referência; rituais de revisão; campeão técnico no squad |

## 16.3. Gatilhos para Evolução — Quando Extrair Reserva como Microsserviço

A extração não é decisão por tempo. É decisão por métrica saturada. Os gatilhos:

1. **p95 da reserva > 500 ms sustentado** por 7 dias consecutivos em janela fora-de-pico, depois de otimizações de banco já aplicadas (índices, vacuum, *connection pooling*).
2. **Contenção de pool de conexões** (esperas por conexão > 50ms p95) que não cede com aumento do pool.
3. **Saturação de banco** (CPU > 70% sustentado fora-de-pico, IOPS no teto do tier).
4. **Necessidade de escalar Reserva em ritmo diferente do resto** (ex.: rodar Reserva em hardware muito mais robusto sem inflar o resto do sistema).
5. **Restrição organizacional**: a partir do momento em que houver dois squads independentes com cadência de release conflitante.

Enquanto nenhum desses gatilhos estiver acionado, extrair é adicionar custo sem colher benefício.

## 16.4. Como Será a Extração (Spike Pré-Calculado)

Sequência aproximada, esperada em até 4 semanas:

1. **Semana 1.** Espelhar schema `reserva` para uma instância dedicada; replicar dados; manter dupla escrita transitória.
2. **Semana 2.** Implementar adapter HTTP de `IReservaApi` apontando para o novo serviço; rodar atrás de feature flag em homologação; bateria de testes de concorrência.
3. **Semana 3.** Implementar a Saga orquestrada (§12.3) substituindo a transação ACID local. Testes de falha (compensação) extensivos.
4. **Semana 4.** Cutover gradual (feature flag por % de tráfego); observação de SLOs; rollback pronto; decomissionamento do código antigo após estabilização.

O custo da extração é estimável porque a arquitetura foi desenhada para suportá-la. Em uma arquitetura sem essas fronteiras, o mesmo movimento seria uma reescrita de meses, não semanas.

## 16.5. Outras Evoluções Antecipadas

- **Notificação como serviço dedicado**: trivial, dado que consome apenas eventos. Faz sentido quando o domínio de notificações ganhar complexidade (preferências do usuário, templates dinâmicos, push, in-app).
- **Métricas como pipeline analítico** (data lake + warehouse): quando produtores demandarem análises mais sofisticadas (cohort, funil, A/B), as projeções no monólito ficam pequenas demais; migrar consumidores de evento para um pipeline analítico apartado.
- **Catálogo com CDN regional**: se o catálogo crescer em volume e o público se internacionalizar, leituras de catálogo podem ser servidas por CDN com invalidação por eventos.

---

# 17. Conclusão

Este trabalho me forçou a ser explícito sobre decisões que, na prática do dia a dia, ficam implícitas. E essa explicitação foi o exercício mais valioso do processo, mais até do que os diagramas ou as especificações de API.

A escolha central do monólito modular não foi tomada por conservadorismo nem por desconhecimento de alternativas. Foi tomada depois de comparar concretamente as opções (§8) e identificar que, neste contexto específico, um squad pequeno com requisito forte de consistência transacional tira mais valor de um deployable único do que de uma malha de serviços. Já vi times pequenos sofrendo com microsserviços prematuros; o custo operacional é real e corrói a capacidade de entrega de um jeito que não fica evidente até você estar no meio do problema. Isso pesou na decisão.

O que tentei garantir ao longo do documento é que as fronteiras sejam reais, não nominais. Schema por módulo, contratos versionados, ADP no CI, outbox transacional, eventos de domínio. São as barreiras que tornam a extração futura possível sem reescrita, e que tornam o monólito de hoje diferente do "big ball of mud" que ele poderia virar sem disciplina. Esse era o risco que mais queria evitar.

Sei que algumas decisões aqui podem ser questionadas. A escolha de não usar Saga hoje, de manter RTO em 15 minutos em vez de investir em multi-região, de adiar chaos engineering: são apostas no contexto atual que podem não se sustentar se o produto crescer de formas que não antecipei. Por isso documentei os gatilhos de evolução explicitamente (§16.3). Não sei se acertei em tudo, mas tentei deixar claro o porquê de cada escolha e quais métricas eu usaria para revisá-las no futuro.

---

# 18. Vídeo Complementar

> **[LINK DO VÍDEO YOUTUBE — a inserir após gravação]**
>
> Conteúdo previsto do vídeo (10–15 min):
> 1. Apresentação do contexto e drivers (1 min)
> 2. Justificativa do monólito modular vs microsserviços (3 min)
> 3. Walkthrough dos diagramas C4 (3 min)
> 4. ADRs principais — seat-locking e waiting room (3 min)
> 5. Roadmap de evolução e gatilhos de extração (2 min)
> 6. Encerramento e perguntas-âncora (1 min)

---

# 19. Referências Bibliográficas

- **Brown, S.** (2018). *The C4 model for visualising software architecture.* c4model.com.
- **Evans, E.** (2003). *Domain-Driven Design: Tackling Complexity in the Heart of Software.* Addison-Wesley.
- **Fowler, M.** (2014). MonolithFirst. martinfowler.com/bliki/MonolithFirst.html
- **Kleppmann, M.** (2016). *How to do distributed locking.* martin.kleppmann.com (artigo sobre Redlock e seus problemas).
- **Kleppmann, M.** (2017). *Designing Data-Intensive Applications.* O'Reilly.
- **Martin, R. C.** (2017). *Clean Architecture.* Prentice Hall.
- **Newman, S.** (2019). *Monolith to Microservices.* O'Reilly.
- **Nygard, M. T.** (2018). *Release It!*, 2ª ed. Pragmatic Bookshelf.
- **Richards, M.; Ford, N.** (2020). *Fundamentals of Software Architecture.* O'Reilly.
- **Richardson, C.** (2018). *Microservices Patterns.* Manning.

---

> *Documento elaborado por Christian Chiavelli — 2026-05-24.
> Entrega acadêmica de pós-graduação — disciplina de Arquitetura de Software.
> Versão 1.0 — congelada para avaliação.*
