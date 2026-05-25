---
title: "Arquitetura de Sistema de Venda de Ingressos Online, Decisões, Trade-offs e Modelo C4"
subtitle: "Monólito Modular com Pipeline de Admissão e Comunicação Orientada a Eventos"
author: "Christian Chiavelli"
discipline: "Arquitetura de Software, Pós-Graduação"
date: "2026-05-24"
version: "1.0"
status: "Final, Entrega Acadêmica"
---

# Sumário

1. [Sumário Executivo](#1-sumário-executivo)
2. [Contexto e Drivers de Negócio](#2-contexto-e-drivers-de-negócio)
3. [Restrições](#3-restrições)
4. [Atributos de Qualidade](#4-atributos-de-qualidade)
5. [Características Arquiteturais Explícitas vs Implícitas](#5-características-arquiteturais-explícitas-vs-implícitas)
6. [Conflitos e Trade-offs entre Atributos](#6-conflitos-e-trade-offs-entre-atributos)
7. [Decisões Arquiteturais (ADRs)](#7-decisões-arquiteturais-adrs)
8. [Avaliação Comparativa de Estilos Arquiteturais](#8-avaliação-comparativa-de-estilos-arquiteturais)
9. [Design Arquitetural](#9-design-arquitetural)
10. [Modelo C4, Visões em Três Níveis](#10-modelo-c4--visões-em-três-níveis)
11. [Contratos de Serviço](#11-contratos-de-serviço)
12. [Consistência Forte vs Consistência Eventual](#12-consistência-forte-vs-consistência-eventual)
13. [Propriedade dos Dados](#13-propriedade-dos-dados)
14. [Impacto na Efetividade dos Times](#14-impacto-na-efetividade-dos-times)
15. [Liderança Técnica e Negociação de Requisitos](#15-liderança-técnica-e-negociação-de-requisitos)
16. [Trade-offs Residuais, Riscos e Roadmap de Evolução](#16-trade-offs-residuais-riscos-e-roadmap-de-evolução)
17. [Conclusão](#17-conclusão)
18. [Vídeo Complementar](#18-vídeo-complementar)
19. [Referências Bibliográficas](#19-referências-bibliográficas)

---

# 1. Sumário Executivo

Este documento descreve a arquitetura de um **Sistema de Venda de Ingressos Online**. O escopo é deliberadamente estreito: foco exclusivo na **experiência de compra**, cobrindo visualização de disponibilidade, reserva temporária de assento, pagamento via gateway externo, emissão de ingresso digital, notificações e métricas para produtores. Operações administrativas, estornos complexos, processamento financeiro profundo e infraestrutura física de acesso ficam fora de escopo.

O sistema tem três drivers de negócio em ordem decreta de prioridade: (1) **consistência de dados**, porque um assento jamais pode ser vendido duas vezes; (2) **escalabilidade elástica para picos extremos**, já que eventos populares geram cargas da ordem de 50 mil usuários concorrentes nos primeiros 60 segundos de venda; e (3) **time-to-market**, com preferência por serviços gerenciados em nuvem em vez de reinventar componentes que já existem prontos.

A decisão arquitetural central é a adoção de um **Monólito Modular** como núcleo, organizado por *bounded contexts* (Catálogo, Reserva, Pagamento, Ingresso, Notificação, Métricas), complementado por dois elementos estruturantes:

- Um **pipeline de admissão** (virtual waiting room) que absorve picos antes que atinjam o domínio transacional, transformando o que seria uma tempestade síncrona em um fluxo controlado.
- Uma **espinha dorsal orientada a eventos** (message broker gerenciado) que desacopla temporalmente o caminho crítico de compra das atividades não-transacionais: notificações, métricas, auditoria, projeções.

Tenho uma preferência declarada por monólito modular, em parte por experiência direta. Já vi mais sistemas sofrerem com microsserviços prematuros do que com monólitos bem estruturados, e acho que o setor de software ainda romantiza demais a ideia de distribuir tudo antes de ter métricas que justifiquem. No contexto deste projeto, com equipe enxuta e sem maturidade operacional consolidada em sistemas distribuídos, essa escolha faz sentido nas três dimensões prioritárias:

- **Consistência forte**: o seat-locking é resolvido com uma transação ACID local de poucos milissegundos contra um banco relacional, sem a complexidade operacional de locks distribuídos ou Sagas de compensação.
- **Time-to-market**: um único pipeline de build/deploy, observabilidade unificada, ausência de coordenação cross-team para mudanças que atravessam módulos.
- **Custo operacional**: footprint mínimo de runtime, rede e infra de coordenação.

O documento deixa explicitamente reservado o gancho de evolução: o módulo de Reserva é o candidato natural a ser extraído como microsserviço dedicado, mas só quando métricas operacionais concretas (saturação do banco no caminho de lock, latência p99 acima do SLO, contenção de pool de conexões) demonstrarem que a granularidade do monólito virou um teto. Antecipar essa extração é cair no antipadrão de **microservice envy**, uma armadilha bem documentada por Richards e Ford (2020).

Em síntese: esta arquitetura privilegia simplicidade hoje, mas instala desde o primeiro dia as barreiras que tornam a extração futura uma operação de refatoração, não uma reescrita. São elas: isolamento de schema por módulo, contratos internos versionados e eventos de domínio explícitos.

---

# 2. Contexto e Drivers de Negócio

## 2.1. Domínio e Escopo

O sistema é um **canal digital de venda de ingressos para eventos com lugar marcado** (shows, espetáculos, esportes). A jornada-alvo, no caminho feliz, é:

1. O comprador acessa a página do evento e visualiza o mapa de assentos com disponibilidade em tempo quase-real.
2. Seleciona um ou mais assentos; o sistema os marca como *reservados temporariamente* sob TTL curto (tipicamente 5 a 10 minutos).
3. O comprador é redirecionado ao **Gateway de Pagamento externo** (tratado como caixa-preta).
4. Confirmado o pagamento, o sistema persiste a venda, **converte a reserva em ingresso emitido**, dispara **notificações assíncronas** (e-mail/SMS) e libera o ingresso digital.
5. Em paralelo, **eventos de domínio** são publicados para alimentar métricas consumidas por produtores de eventos.

## 2.2. Stakeholders

Os principais interessados no sistema são basicamente três grupos: compradores, produtores de eventos e a equipe de engenharia, com alguns atores externos relevantes.

Os **compradores** são quem mais vai sentir na pele qualquer problema: eles querem conseguir o ingresso no momento do pico, sem perder o assento que escolheram. Para eles importa disponibilidade, latência percebida e, talvez mais importante do que parece, a sensação de que o processo é justo. Se vinte mil pessoas bateram na porta ao mesmo tempo, que a ordem seja determinada por algo previsível, não por sorte de rede.

Os **produtores de eventos** têm um interesse diferente: querem acompanhar vendas, conversão e capacidade preenchida. O dado não precisa ser em tempo real estrito, mas precisa ser confiável. Um número errado de ingressos vendidos pode gerar decisões ruins sobre logística do evento.

Os **sistemas externos** (Gateway de Pagamento e provedores de e-mail/SMS) não são stakeholders no sentido humano, mas impõem restrições reais: o gateway espera requisições corretas e idempotentes; o provedor de notificações opera com quotas e throttling. Ignorar isso no design é a receita para surpresas em produção.

A **equipe de engenharia** quer poder evoluir o sistema sem medo de quebrar coisas não relacionadas. E a **equipe de negócio** quer lançar campanhas e novos eventos com agilidade. Essas duas expectativas ficam em tensão quando o sistema acumula dívida técnica, o que é mais um argumento para investir desde o início na modularidade interna.

## 2.3. Drivers de Negócio Prioritizados

A ordem aqui não é decorativa. Ela é a função de fitness arquitetural do sistema. Toda decisão de design subsequente é avaliada contra esta hierarquia.

### Driver 1: Confiabilidade / Consistência de Dados (`crítico, inegociável`)

**Manifesto:** o mesmo assento jamais pode ser vendido duas vezes. Double-booking é o pesadelo do negócio: gera reembolso, hostilidade do comprador, dano reputacional desproporcional ao prejuízo financeiro direto, e, em casos de eventos sem ingressos remanescentes, algo que funciona na prática como fraude perceptual.

**Implicação arquitetural:** o seat-locking exige **consistência forte e linearizável** no ponto de reserva. Consistência eventual é inaceitável neste subdomínio. Isso elimina, no caminho crítico, soluções como CRDTs ou eventual replication entre regiões.

### Driver 2: Escalabilidade Elástica para Picos

**Manifesto:** uma venda de show popular pode ter 30k a 80k usuários acessando simultaneamente nos primeiros 30 a 60 segundos. O regime fora desses picos é dramaticamente diferente, tipo 100x menos carga. Provisionar para o pico permanentemente é antieconômico.

**Implicação arquitetural:** elasticidade horizontal na camada de admissão e nas camadas stateless; um **mecanismo explícito de absorção de pico** (virtual waiting room); separação clara entre carga não-crítica (browsing) e carga transacional (reserva e pagamento).

### Driver 3: Time-to-Market e Simplicidade

**Manifesto:** este é um sistema novo, com equipe enxuta, sem maturidade operacional consolidada em microsserviços distribuídos. O custo de um sistema distribuído mal operado é maior do que o custo de um sistema bem modularizado. Time-to-market vence sofisticação prematura.

**Implicação arquitetural:** preferir **serviços gerenciados** (RDS/Aurora, ElastiCache, SQS/SNS, EKS/ECS Fargate, API Gateway gerenciado) a operar componentes próprios; **um único deployable** para o core; observabilidade convergente em uma stack só.

---

# 3. Restrições

Restrições não são preferências: são fronteiras dentro das quais a arquitetura precisa caber. Documentá-las explicitamente evita decisões que parecem boas em isolamento mas violam o contorno do projeto.

## 3.1. Restrições Técnicas

A restrição mais impactante é a integração com o **Gateway de Pagamento externo** (RT-01): um sistema opaco, com latências e taxas de falha que não controlamos. Toda integração com pagamento precisa ser idempotente, preferencialmente assíncrona onde possível, com circuit breaker e retries com backoff exponencial. Essa não é negociável.

Em termos parecidos, o **provedor de e-mail/SMS** (RT-02) opera com quotas por minuto e janelas de throttling. Isso significa que notificações precisam ser enfileiradas, com rate limiter antes de chegar ao provedor. Tentar enviar em rajada resulta em erros 429 e potencial bloqueio da conta.

Há duas restrições de natureza organizacional que acabam virando restrições técnicas na prática. Não há time dedicado de SRE/Platform 24×7 no estágio atual (RT-03), o que reforça a escolha por serviços gerenciados e minimização da superfície operacional. E a stack já consolidada no time é .NET no backend, TypeScript no front, banco relacional gerenciado e infra em cloud pública (RT-04): não faz sentido introduzir tecnologias novas sem uma justificativa muito clara, porque o custo de aprendizado e operação não é gratuito.

Por fim, o **orçamento de infraestrutura** (RT-05) precisa escalar com a receita, não linearmente com o pico instantâneo. Isso implica capacidade reservada mínima, autoscaling agressivo e uso de spot/preemptível em workers não críticos.

## 3.2. Restrições Organizacionais

A equipe tem entre 6 e 10 engenheiros, organizada em um único squad. A Lei de Conway é real: a granularidade arquitetural tende a refletir o tamanho do time. Um único deployable serve melhor um único squad do que uma coleção de microsserviços que exige coordenação constante entre pessoas.

Mais relevante ainda: não existe cultura instalada de operação de sistemas distribuídos aqui. Sem tracing distribuído maduro, sem práticas de mTLS ou service mesh, sem chaos engineering regular, adotar microsserviços seria criar as condições clássicas de distributed monolith, que é pior do que um monólito simples porque tem a complexidade de um sem a coesão do outro.

O ciclo de release é semanal, com janelas de hotfix sob demanda. Isso significa que o pipeline de deploy do monólito modular precisa ser rápido (menos de 10 minutos) e reversível.

## 3.3. Restrições Regulatórias

Três restrições regulatórias merecem atenção explícita. A **LGPD** exige que dados pessoais de compradores (nome, CPF, e-mail) tenham proteção adequada, base legal e direito ao esquecimento. Isso implica um módulo de Identidade/PII isolado, criptografia em repouso, log de acesso e processo de anonimização.

O **PCI-DSS**, por outro lado, tem seu escopo drasticamente reduzido pela arquitetura: o sistema não tokeniza nem armazena dados de cartão. Toda interação cartão-banco passa pelo Gateway, e o sistema só armazena tokens opacos retornados por ele.

Por fim, logs de transações financeiras precisam ser auditáveis por período mínimo legal (geralmente 5 anos no Brasil). Isso aponta para event sourcing parcial no módulo de Pagamento e Ingresso, ou append-only em storage frio (S3 + Glacier).

---

# 4. Atributos de Qualidade

A taxonomia adotada segue Richards e Ford (2020): **Operacionais, Estruturais e Transversais**. Para cada atributo prioritário, descrevo: (a) a definição contextualizada ao problema, não a genérica de livro; (b) a métrica objetiva com limiar; e (c) como o atributo influencia a decisão arquitetural. Um atributo sem influência sobre o desenho é decorativo.

## 4.1. Atributos Operacionais

### 4.1.1. Disponibilidade

A disponibilidade durante janelas de venda é crítica; fora delas, o sistema pode tolerar degradação parcial. A meta é **99,9% mensal** no caminho de compra (cerca de 43 minutos de indisponibilidade tolerada por mês) e **99,5% mensal** nas funcionalidades de métricas para produtores.

Isso força algumas decisões estruturais: camadas stateless na borda, health checks profundos, multi-AZ obrigatório no banco e no broker. E exige graceful degradation: se o módulo de Métricas cair, a compra precisa continuar funcionando.

### 4.1.2. Escalabilidade

A meta é suportar **50.000 usuários simultâneos** na fila de admissão e **5.000 reservas por minuto** no domínio transacional. O scale-out dos pods da API deve acontecer em até **90 segundos** após disparo do gatilho.

Isso torna o virtual waiting room obrigatório, não um nice-to-have. Sem ele, qualquer pico de venda derruba o banco ou satura a fila de lock. Também implica connection pooling bem dimensionado, cache agressivo do catálogo (leitura dominante) e write path dimensionado para o pico.

### 4.1.3. Performance

As metas de latência no caminho crítico de compra:

- **p50 < 100 ms** para visualização de disponibilidade (com cache)
- **p95 < 300 ms** para a transação de reserva (commit do lock no banco)
- **p99 < 800 ms** para o caminho de pagamento (excluindo tempo do Gateway externo)

Isso requer índices cuidadosos no banco, cache do mapa de assentos com invalidação por evento de domínio e ausência de chamadas síncronas a serviços externos no caminho crítico, exceto o próprio Gateway.

### 4.1.4. Recoverability

**RTO menor que 15 minutos e RPO menor que 1 minuto.** Banco gerenciado com PITR (point-in-time recovery), deploys com estratégia blue/green ou rolling, e idempotência em todo handler de evento para permitir reprocessamento após falha.

## 4.2. Atributos Estruturais

### 4.2.1. Modularidade

O sistema precisa permitir que módulos evoluam com mínimo impacto cruzado. A meta concreta: **zero dependências cíclicas** entre módulos (validado em CI via análise estática) e **zero acesso direto de um módulo ao schema de outro** (validado por convenção de schemas separados e revisão obrigatória).

A comunicação inter-módulo ocorre via interfaces de aplicação ou eventos de domínio. Não via acesso direto a tabelas alheias.

### 4.2.2. Testabilidade

**Cobertura de domínio > 85%**; um **teste de concorrência específico** para seat-locking com simulação de N escritores simultâneos; pirâmide de testes saudável (mais de 70% unitários, menos de 10% E2E).

Isso exige domínio isolado de I/O, adapters injetáveis e testes de integração contra banco real (testcontainers ou ambiente efêmero).

### 4.2.3. Evolutibilidade

Capacidade de extrair o módulo de Reserva como serviço em menos de 4 semanas de trabalho, quando justificável por métricas. Para chegar lá: schemas isolados, contratos internos versionados e eventos de domínio com schema registry desde o dia 1.

### 4.2.4. Manutenibilidade

Change failure rate menor que 15% (métrica DORA) e MTTR menor que 1 hora. O pré-requisito é observabilidade rica: logs estruturados com correlação por traceId, feature flags para mudanças de risco.

## 4.3. Atributos Transversais (Cross-cutting)

### 4.3.1. Segurança

Três preocupações principais: bots de cambista, proteção de PII e canal de pagamento. As metas: **0 vazamentos de PII**; rate limiting bloqueando mais de 95% das tentativas automatizadas em janelas de venda; **0 dados de cartão tocando o sistema**.

Para isso: WAF + bot management na borda, rate limiting por IP/conta/dispositivo, CAPTCHA adaptativo na entrada da fila, tokenização pelo Gateway e least privilege nas IAM roles.

### 4.3.2. Observabilidade

Capacidade de responder o que aconteceu no caminho de compra em menos de 5 minutos. Isso exige **100% das requisições com traceId**, logs estruturados e métricas de negócio (reservas iniciadas, reservas concluídas, abandono no Gateway, taxa de expiração de lock) em dashboard acessível para a equipe.

Esse atributo costuma ser subestimado em projetos do tipo. Na minha experiência, é o que faz diferença entre um time que diagnostica incidentes em 20 minutos e um time que passa 4 horas em call olhando para logs em texto plano. OpenTelemetry desde o dia 1 não é overhead; é o que vai salvar o time em produção.

### 4.3.3. Consistência de Dados

Já discutida como Driver 1, elevada aqui a atributo transversal porque atravessa Reserva, Pagamento e Ingresso. A meta é **double-booking rate = 0** (intolerância absoluta) e divergência entre Pagamento autorizado e Ingresso emitido menor que 0,01%, sempre detectável por reconciliação assíncrona.

Isso se traduz em transação ACID local para o trio Reserva → Pagamento → Ingresso, e eventos de domínio publicados após o commit (outbox pattern) para garantir at-least-once sem perder o estado autoritativo.

### 4.3.4. Custo Total de Propriedade

Custo de infra por ingresso vendido deve ser menor que um percentual do fee (a calibrar empiricamente nos primeiros 6 meses). O caminho: serviços gerenciados, autoscaling, uso de spot em workers de notificação e tiering frio de logs e auditoria.

## 4.4. Tabela-Resumo de Prioridade

| Atributo | Categoria | Prioridade | Métrica/Limiar |
|---|---|---|---|
| Consistência de dados (no seat-locking) | Transversal | **Crítica** | double-booking = 0 |
| Disponibilidade no caminho de compra | Operacional | **Crítica** | 99,9% mensal |
| Escalabilidade elástica | Operacional | **Crítica** | 50k concorrentes; 5k reservas/min |
| Performance (latência da reserva) | Operacional | **Alta** | p95 < 300 ms |
| Segurança contra bots | Transversal | **Alta** | >95% bloqueio |
| Modularidade / Evolutibilidade | Estrutural | **Alta** | extração de Reserva em <4 sem |
| Observabilidade | Transversal | **Alta** | 100% tracing |
| Recoverability | Operacional | Média | RTO 15 min / RPO 1 min |
| Manutenibilidade | Estrutural | Média | CFR < 15%, MTTR < 1h |
| Custo | Transversal | Média | ajustar empiricamente |

---

# 5. Características Arquiteturais Explícitas vs Implícitas

Richards e Ford (2020) fazem uma distinção útil: **características explícitas** são as que os stakeholders nomeiam como requisitos não-funcionais; **características implícitas** são as que o arquiteto precisa reconhecer mesmo sem ter sido pedido. Ignorar as implícitas é a fonte mais comum de retrabalho arquitetural tardio.

## 5.1. Características Explícitas

As três que vêm diretamente dos drivers declarados:

- **Confiabilidade / Consistência transacional** (Driver 1)
- **Escalabilidade elástica para picos** (Driver 2)
- **Time-to-market / Simplicidade operacional** (Driver 3)

Essas são contratuais: o sistema falha o teste de aceitação se não as atender.

## 5.2. Características Implícitas

Algumas das características mais importantes deste sistema não aparecem em nenhum requisito formal. Vou descrever as principais e por que importam aqui.

**Justiça (fairness) percebida** é talvez a mais subestimada. Ninguém pediu formalmente, mas usuários numa abertura de venda têm uma expectativa muito forte de que a ordem é justa. Quer dizer, mais precisamente: não é que eles exijam FIFO de forma consciente, mas qualquer sistema que pareça aleatório vai gerar reclamação e manchete. Isso define a estratégia da virtual waiting room: FIFO por timestamp de entrada na fila, não loteria.

**Idempotência ponta a ponta** é exigência de qualquer integração real com gateway de pagamento. Influencia o design dos endpoints (chave de idempotência), do outbox e do consumo de eventos. É a diferença entre um sistema que sobrevive a retries e um que gera double-charges.

**Resiliência a falhas de terceiros** não foi nomeada nos requisitos, mas gateway e provedores externos vão falhar. Isso é certeza estatística. Circuit breaker, retries com backoff e dead letter queue não são opcionais.

**Backpressure** define o comportamento do sistema quando o downstream não acompanha. Filas com limite e descarte controlado. Nunca acumular reservas além da capacidade do banco.

**Auditabilidade** aparece mais como exigência regulatória do que como requisito funcional, mas se manifesta quando há incidentes. Daí o event sourcing parcial no módulo de Pagamento.

**Fusos horários** parecem detalhe, mas um bug aqui é catastrófico em uma virada de horário, especialmente em eventos que abrem venda à meia-noite. Sempre UTC no armazenamento, conversão apenas na borda.

**Deployabilidade contínua** é implicada pelo ciclo de release semanal. Trunk-based development, feature flags e zero-downtime deploy não são luxo: são condições para o time operar sem ansiedade a cada deploy.

**Observabilidade emocional do produto** é aquela dimensão onde métricas de negócio (taxa de abandono no gateway, fila com mais de X minutos de espera) precisam ser visíveis tanto para engenharia quanto para produto, no mesmo pipeline. Quando cada time tem dashboard separado, as interpretações divergem e fica difícil alinhar o que está acontecendo em produção.

O risco clássico em sistemas de venda em pico é projetar para as características explícitas e esquecer fairness e backpressure, descobrindo no dia da venda que usuários acharam a fila injusta ou que o banco caiu por excesso de conexões abertas. Esta arquitetura trata as implícitas com a mesma seriedade das explícitas, e isso se reflete em ADRs específicos (notavelmente ADR-003, sobre o pipeline de admissão).

---

# 6. Conflitos e Trade-offs entre Atributos

Arquitetura é escolha. Todo atributo que você prioriza cria pressão contrária em outro. O que listo abaixo são os trade-offs mais relevantes deste sistema, com a posição que adotei e o raciocínio por trás.

## 6.1. Conflito 1: Consistência Forte vs Disponibilidade (Teorema CAP)

O Driver 1 exige consistência linearizável no seat-locking. O Driver 2 exige alta disponibilidade no pico. Em uma partição de rede entre nó primário e réplica do banco, o CAP nos obriga a escolher.

No subdomínio de Reserva e Pagamento, adotei **CP**: em caso de partição, preferimos falhar requisições de reserva (devolver 503 com Retry-After) a permitir double-booking. Em Catálogo, Notificações e Métricas, adotei **AP**: ler de réplica é aceitável, com staleness de alguns segundos.

A lógica é direta: vender duas vezes o mesmo assento é pior do que recusar uma venda. O custo de um 503 é finito e recuperável. O custo de um double-booking é reputacional e, eventualmente, legal. A mitigação principal é multi-AZ síncrono no banco, que minimiza a probabilidade de partições significativas; e a rota de leitura do Catálogo é separada, com staleness aceitável.

## 6.2. Conflito 2: Time-to-Market vs Escalabilidade Granular

Microsserviços oferecem escalabilidade granular: escalar só o módulo de Reserva durante picos, sem inflar o resto. Monólito modular escala em granularidade de processo inteiro, o que é mais grosseiro. Mas microsserviços impõem custo operacional alto desde o dia 1.

A posição: monólito modular agora, com extração cirúrgica de Reserva quando métricas justificarem. Não escalar granularmente é um trade-off consciente.

No regime atual, escalar horizontalmente o monólito inteiro (stateless, exceto pela conexão com o banco) é barato e linear. O gargalo não é CPU dos pods, é o banco. Quebrar em serviços antes de tocar o gargalo real não resolve o problema; cria outros. A regra que sigo: só pague custo de microsserviço quando tiver benefício concreto de microsserviço para colher.

## 6.3. Conflito 3: Fairness Percebida vs Performance Pura

Servir o usuário mais rápido, sem fila, seria ótimo para latência média. Mas num pico de 50 mil pessoas no segundo zero, atendê-los todos imediatamente derruba o banco. E pior: usuários percebem essa derrubada como injustiça, porque quem "ganha" é quem teve melhor sorte de rede.

Adotei pipeline de admissão com FIFO honesto: o tempo de chegada à fila determina o turno. Há uma penalidade de latência (segundos de espera), mas em troca de previsibilidade e percepção de justiça.

E aqui está um ponto que eu acho que não é óbvio: um sistema "rápido para alguns e indisponível para outros" é pior em NPS do que um sistema "lento para todos mas justo". Fairness afeta reputação de forma desproporcional, especialmente em eventos onde as pessoas têm expectativa emocional alta.

## 6.4. Conflito 4: Simplicidade Operacional vs Resiliência Maximal

Maior resiliência (multi-região ativo-ativo, replicação assíncrona cross-region, autoscaling agressivo, chaos engineering regular) custa complexidade e dinheiro. O Driver 3 pede simplicidade.

A posição: **multi-AZ sim, multi-região não** no estágio atual. RTO de 15 minutos é suficiente para o negócio. Sem chaos engineering institucionalizado no dia 1; apenas game days trimestrais.

Multi-região tem custo de complexidade desproporcional ao ganho marginal de RPO/RTO neste momento. O dinheiro investido ali seria melhor gasto em observabilidade e runbooks bem mantidos.

## 6.5. Conflito 5: Acoplamento por Banco vs Pragmatismo

Em monólito modular, o pragmatismo aponta para um único banco. Mas isso cria o risco do shared database antipattern: módulos lendo schemas alheios e criando acoplamento por dados que dificulta qualquer extração futura.

A posição adotada: **um banco, schemas separados por módulo, com proibição de cross-schema queries**, validada por revisão e por convenção (linter de SQL). É um compromisso entre simplicidade operacional e isolamento lógico. Não é perfeito, mas é defensável dado o contexto. O detalhamento está em ADR-005.

---
