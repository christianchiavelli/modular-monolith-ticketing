workspace "Sistema de Venda de Ingressos Online" "Modelo C4 do sistema descrito no relatório acadêmico" {

    !identifiers hierarchical

    model {

        // Atores
        comprador = person "Comprador" "Usuário final que compra ingressos para eventos."
        produtor  = person "Produtor de Eventos" "Consulta métricas de vendas do próprio evento."

        // Sistema principal
        sistema = softwareSystem "Sistema de Venda de Ingressos Online" "Plataforma de venda de ingressos com lugar marcado." {

            webApp        = container "Web App SPA" "Interface do comprador e do produtor." "TypeScript / Framework reativo"
            waitingRoom   = container "Virtual Waiting Room" "Pipeline de admissão (FIFO, token bucket, JWT de admissão)." "Serviço gerenciado"
            api           = container "API Backend (Monólito Modular)" "Núcleo transacional com todos os bounded contexts." ".NET / Kestrel" {
                edge          = component "API Edge / Auth Middleware" "Valida JWT, valida token de admissão, rate limit, idempotência."
                catalogo      = component "Catálogo" "Eventos, setores, assentos, disponibilidade derivada."
                reserva       = component "Reserva" "Seat-locking via TTL. Ciclo HELD/CONFIRMED/EXPIRED."
                pagamento     = component "Pagamento" "Orquestra Gateway externo, idempotência, reconciliação."
                ingresso      = component "Ingresso" "Emite, invalida, QR Code, assinatura."
                notificacaoC  = component "Notificação (API)" "Apenas endpoints de consulta. Envio fica no Worker."
                metricas      = component "Métricas" "Projeções de leitura para produtores."
                outbox        = component "Outbox / Event Publisher" "Garante publicação transacional dos eventos de domínio."
                observ        = component "Observabilidade (OTel)" "Tracing, métricas, logs."
                resil         = component "Resiliência" "Retry, circuit breaker, timeouts."
                idem          = component "Idempotência" "Middleware HTTP e tabela idempotency_keys."
            }
            workerNotif   = container "Worker de Notificações" "Consome eventos, envia e-mail e SMS, faz retries." ".NET worker service"
            workerProj    = container "Worker de Projeções" "Consome eventos, atualiza projeções de leitura." ".NET worker service"
            outboxRelay   = container "Outbox Relay" "Lê a tabela outbox e publica no broker." "Processo leve"
            db            = container "Banco Relacional Gerenciado" "Schemas isolados por módulo. Multi-AZ. PITR." "PostgreSQL / Aurora" {
                tags "Database"
            }
            cache         = container "Cache Distribuído" "Mapa de assentos, idempotência, sessões." "Redis gerenciado" {
                tags "Database"
            }
            broker        = container "Message Broker" "Eventos de domínio com DLQs." "SNS+SQS / EventBridge" {
                tags "Broker"
            }
            observPipe    = container "Pipeline de Observabilidade" "Coletor OTel para backend de logs, métricas e traces." "OpenTelemetry"
        }

        // Sistemas externos
        gateway   = softwareSystem "Gateway de Pagamento" "Processador externo. Caixa-preta." "Externo" {
            tags "External"
        }
        emailSms  = softwareSystem "Provedor de E-mail / SMS" "Provedor externo de envio." "Externo" {
            tags "External"
        }
        idp       = softwareSystem "Provedor de Identidade" "OIDC externo." "Externo" {
            tags "External"
        }

        // Relacionamentos - Nível de Contexto
        comprador -> sistema "Navega catálogo, reserva, paga"
        produtor  -> sistema "Consulta métricas de vendas"
        sistema   -> gateway "Autoriza pagamento (HTTPS, webhook)"
        sistema   -> emailSms "Envia notificações"
        sistema   -> idp "Autentica usuários via OIDC"

        // Relacionamentos - Nível de Contêiner
        comprador -> sistema.webApp "Acessa via HTTPS"
        produtor  -> sistema.webApp "Acessa via HTTPS"
        sistema.webApp      -> sistema.waitingRoom "Solicita token de admissão"
        sistema.waitingRoom -> sistema.api "Encaminha tráfego admitido"
        sistema.webApp      -> idp "OIDC"
        sistema.api         -> idp "Valida JWT"

        sistema.api         -> sistema.db "Lê, escreve e persiste eventos no outbox (SQL/TCP)"
        sistema.api         -> sistema.cache "Lê e escreve (RESP)"
        sistema.outboxRelay -> sistema.db "Lê outbox"
        sistema.outboxRelay -> sistema.broker "Publica eventos"

        sistema.workerNotif -> sistema.broker "Consome eventos"
        sistema.workerNotif -> emailSms "Envia notificações (HTTPS)"
        sistema.workerProj  -> sistema.broker "Consome eventos"
        sistema.workerProj  -> sistema.db "Atualiza projeções de leitura"

        sistema.api -> gateway "Redirect e webhook idempotente"

        sistema.api         -> sistema.observPipe "Telemetria"
        sistema.workerNotif -> sistema.observPipe "Telemetria"
        sistema.workerProj  -> sistema.observPipe "Telemetria"

        // Relacionamentos - Nível de Componente (dentro da API)
        sistema.api.edge -> sistema.api.catalogo
        sistema.api.edge -> sistema.api.reserva
        sistema.api.edge -> sistema.api.pagamento
        sistema.api.edge -> sistema.api.ingresso
        sistema.api.edge -> sistema.api.notificacaoC
        sistema.api.edge -> sistema.api.metricas

        sistema.api.reserva   -> sistema.api.catalogo "Valida disponibilidade"
        sistema.api.pagamento -> sistema.api.reserva  "Confirma reserva em transação ACID local"
        sistema.api.ingresso  -> sistema.api.reserva  "Lê dados da reserva confirmada"
        sistema.api.ingresso  -> sistema.api.pagamento "Lê dados do pagamento autorizado"

        sistema.api.catalogo  -> sistema.api.outbox "Publica eventos de domínio"
        sistema.api.reserva   -> sistema.api.outbox "Publica eventos de domínio"
        sistema.api.pagamento -> sistema.api.outbox "Publica eventos de domínio"
        sistema.api.ingresso  -> sistema.api.outbox "Publica eventos de domínio"

        sistema.api.catalogo  -> sistema.api.observ
        sistema.api.reserva   -> sistema.api.observ
        sistema.api.pagamento -> sistema.api.observ
        sistema.api.ingresso  -> sistema.api.observ

        sistema.api.pagamento -> sistema.api.resil "Circuit breaker para Gateway"
        sistema.api.edge      -> sistema.api.idem  "Chave de idempotência por requisição"
    }

    views {

        systemContext sistema "Contexto" "Diagrama C4 Nível 1 - Contexto do sistema." {
            include *
            autolayout lr
        }

        container sistema "Conteineres" "Diagrama C4 Nível 2 - Conteineres do sistema." {
            include *
            autolayout tb
        }

        component sistema.api "Componentes" "Diagrama C4 Nível 3 - Componentes da API Backend (Monólito Modular)." {
            include *
            autolayout tb
        }

        styles {
            element "Person" {
                shape Person
                background #08427b
                color #ffffff
            }
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "Component" {
                background #85bbf0
                color #000000
            }
            element "Database" {
                shape Cylinder
                background #438dd5
                color #ffffff
            }
            element "Broker" {
                shape Pipe
                background #438dd5
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
        }

        theme default
    }
}