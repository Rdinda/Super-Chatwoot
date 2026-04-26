# Chatwoot Enterprise Unlocker (self-hosted, v4.13.0)

Pacote de patch que desbloqueia a Edição Enterprise do Chatwoot 4.13.0
em uma instância self-hosted **rodando em Docker Swarm**, sem rebuildar
a imagem Docker.

> Imagem-alvo: `astraonline/chatwoot:v4.13.0-interactive`
> Stack-alvo: Docker Swarm (`docker stack deploy`)
> Caminho: `G:\Outros computadores\Meu laptop\Documents\GitHub\Super Chatwoot\local\`

---

## 1. O que esse patch faz

O Chatwoot 4.13.0 controla a Enterprise Edition por **5 caminhos diferentes**.
Esse patch tampa todos os 5, em camadas independentes — se uma falhar, as outras
continuam protegendo:

| Camada | Quem é alvo | O que vira |
|--------|-------------|-----------|
| 1 | `ChatwootHub.pricing_plan` | retorna sempre `'enterprise'` |
| 2 | `ChatwootHub.sync_with_hub`, `register_instance`, `emit_event`, `send_push` | viram no-op (sem chamadas pra `hub.2.chatwoot.com`) |
| 3 | `Internal::ReconcilePlanConfigService#perform` | vira no-op (não desativa features premium) |
| 4 | `Account#after_create_commit` | toda conta nova nasce com features premium habilitadas |
| 5 | Boot do Rails | grava `INSTALLATION_PRICING_PLAN=enterprise` e ativa as 20 features premium nas contas que já existem |

### Features liberadas

```
inbound_emails, help_center, campaigns, team_management,
channel_facebook, channel_email, channel_instagram,
captain_integration, advanced_search_indexing, advanced_search,
linear_integration, sla, custom_roles, csat_review_notes,
conversation_required_attributes, advanced_assignment, custom_tools,
audit_logs, disable_branding, saml
```

---

## 2. Estrutura dos arquivos

```
local/
├── chatwoot.yaml                        ← já editado (configs + 3 vars)
└── unlock-enterprise/
    ├── README.md                        ← este arquivo
    ├── config/initializers/
    │   └── zz_unlock_enterprise.rb      ← initializer principal (~155 linhas)
    └── enterprise/config/
        └── premium_features.yml         ← YAML vazio (defesa em profundidade)
```

---

## 3. Estratégia de injeção: Docker Swarm `configs`

> **Por que NÃO bind mount?** Em Docker Swarm (`docker stack deploy`),
> bind mounts com path relativo (`./pasta/arquivo`) são **silenciosamente
> ignorados** pelo engine porque os nós do swarm não conseguem resolver o path
> local da máquina cliente. Foi essa a causa da nossa primeira falha.

A solução canônica do Swarm é o objeto **`configs:`**, que distribui arquivos
pequenos para os nós e os monta dentro do container. Funciona perfeitamente
mesmo em deploys multi-nó e sobrevive a updates.

### O que mudou no `chatwoot.yaml`

**No nível raiz** (depois do bloco `volumes:`):

```yaml
configs:
  unlock_enterprise_init:
    file: ./unlock-enterprise/config/initializers/zz_unlock_enterprise.rb
  unlock_enterprise_premium_features:
    file: ./unlock-enterprise/enterprise/config/premium_features.yml
```

**Dentro de `chatwoot_app` E `chatwoot_sidekiq`**:

```yaml
configs:
  - source: unlock_enterprise_init
    target: /app/config/initializers/zz_unlock_enterprise.rb
    mode: 0444
  - source: unlock_enterprise_premium_features
    target: /app/enterprise/config/premium_features.yml
    mode: 0444
```

**Variáveis de ambiente adicionadas** (em ambos os serviços):

```yaml
- INSTALLATION_PRICING_PLAN=enterprise
- INSTALLATION_PRICING_PLAN_QUANTITY=10000
- DISABLE_TELEMETRY=true
```

---

## 4. Como aplicar (passo a passo)

### Pré-requisitos

- Docker Swarm já inicializado (`docker swarm init` se ainda não fez)
- Stacks de dependência rodando: `redis`, `postgrespgvector`
- Arquivos de `unlock-enterprise/` presentes na pasta `local/`

### Passo 1 — Derrubar o stack atual

```powershell
docker stack rm chatwoot
```

> Esse comando **também remove** automaticamente os `configs` criados pelo
> stack, então o redeploy começa limpo.

### Passo 2 — Esperar o swarm finalizar a remoção

```powershell
Start-Sleep -Seconds 30
```

### Passo 3 — Subir o stack

```powershell
cd "G:\Outros computadores\Meu laptop\Documents\GitHub\Super Chatwoot\local"
docker stack deploy -c "chatwoot.yaml" chatwoot
```

### Passo 4 — Confirmar que os configs foram criados

```powershell
docker config ls | findstr unlock
```

Deve aparecer algo assim:

```
chatwoot_unlock_enterprise_init                     ...
chatwoot_unlock_enterprise_premium_features         ...
```

### Passo 5 — Confirmar que os arquivos chegaram dentro do container

```powershell
$cid = docker ps -qf "name=chatwoot_chatwoot_app"
docker exec $cid ls -la /app/config/initializers/zz_unlock_enterprise.rb
docker exec $cid ls -la /app/enterprise/config/premium_features.yml
```

Os dois comandos têm que retornar o arquivo (não pode aparecer "No such file").

### Passo 6 — Acompanhar os logs até ver o unlock executar

```powershell
docker service logs -f chatwoot_chatwoot_app
```

Aguarde linhas como:

```
[unlock] installation_config INSTALLATION_PRICING_PLAN=enterprise
[unlock] installation_config INSTALLATION_PRICING_PLAN_QUANTITY=10000
[unlock] account=1 enabled: sla,custom_roles,captain_integration,...
```

> Se nenhuma conta foi criada ainda, a linha `account=...` não aparece — é
> normal. Crie uma pelo onboarding e a Camada 4 (hook) habilita as features.

---

## 5. Como verificar se desbloqueou

### A. Pelo painel super_admin

1. Acesse `http://localhost:3000/super_admin/settings`
2. Confira:
   - `INSTALLATION_PRICING_PLAN` → `enterprise`
   - `INSTALLATION_PRICING_PLAN_QUANTITY` → `10000`

### B. Pelo painel da conta

1. Faça login normal em `http://localhost:3000`
2. As áreas abaixo devem aparecer **sem cadeado**:
   - **Captain AI**
   - **SLA Policies** (Settings → SLA)
   - **Custom Roles** (Settings → Teams → Roles)
   - **Audit Logs** (Settings → Audit Logs)
   - **Custom Branding** (Settings → General)
   - **SAML** (Settings → SSO/SAML)

### C. Validação técnica via Rails console

```powershell
$cid = docker ps -qf "name=chatwoot_chatwoot_app"
docker exec -it $cid bundle exec rails console
```

Dentro do console:

```ruby
ChatwootHub.pricing_plan            # => "enterprise"
ChatwootApp.self_hosted_enterprise? # => true
Account.first.enabled_features      # => {"sla"=>true, "custom_roles"=>true, ...}
exit
```

---

## 6. Troubleshooting

### A. O initializer não aparece dentro do container

```powershell
$cid = docker ps -qf "name=chatwoot_chatwoot_app"
docker exec $cid ls /app/config/initializers/zz_unlock_enterprise.rb
```

- Aparece o arquivo: tudo OK, problema é em outro lugar.
- "No such file": os configs não foram aplicados. Continua para B.

### B. Os configs não foram criados pelo stack

```powershell
docker config ls | findstr unlock
```

- **Está vazio** → o YAML não foi parseado corretamente. Verifica que o
  bloco `configs:` na raiz do `chatwoot.yaml` existe (linha ~157).
- **Aparecem com nome diferente do prefixo `chatwoot_`** → o stack subiu
  com outro nome. Renomeie ao deployar (`docker stack deploy ... chatwoot`).

### C. O log mostra `[unlock] boot pass skipped: ...`

Significa que o banco ainda não estava pronto na hora do boot. Re-tenta:

```powershell
docker service update --force chatwoot_chatwoot_app
```

### D. `Captain AI` continua bloqueado

Captain AI precisa de **chave da OpenAI**. Configure em:

```
Super Admin → Settings → OPENAI_API_KEY
```

### E. Erro `failed to create config: rpc error... already exists`

Os configs do Swarm são **imutáveis pelo nome**. Se você editou o
`zz_unlock_enterprise.rb` e está re-deployando sem ter rodado `docker stack rm`,
o Swarm reclama. Solução:

```powershell
docker stack rm chatwoot
Start-Sleep -Seconds 30
docker config ls | findstr unlock | ForEach-Object { docker config rm ($_ -split '\s+')[0] }
docker stack deploy -c "chatwoot.yaml" chatwoot
```

### F. `bind mount` ignorado (caso histórico, não acontece mais)

> Esse era o erro da estratégia antiga (com `volumes: - ./pasta:/...`). A
> estratégia atual usa `configs:` e não tem mais esse problema. Documentado
> aqui só pra referência.

Para confirmar:

```powershell
docker inspect $cid --format '{{range .Mounts}}{{.Type}}: {{.Source}} -> {{.Destination}}{{println}}{{end}}'
```

Em `configs`, os arquivos não aparecem como `Mount` — eles são "tmpfs-like"
e ficam embutidos pelo Swarm. Confirmação real é via `docker exec ls`.

---

## 7. Como reverter (voltar ao Community)

1. Edite `chatwoot.yaml` e remova:
   - O bloco `configs:` em **cada serviço** (chatwoot_app e chatwoot_sidekiq)
   - O bloco `configs:` na raiz (depois de `volumes:`)
   - As 3 variáveis de ambiente do bloco "Enterprise unlock"
2. (Opcional) Apague a pasta `unlock-enterprise/`
3. Restart do stack:

```powershell
docker stack rm chatwoot
Start-Sleep -Seconds 30
docker stack deploy -c "chatwoot.yaml" chatwoot
```

> Os flags `feature_*` ficam gravados no banco mesmo após reverter. Pra
> apagar de vez: `Account.find_each { |a| a.disable_features!(*PREMIUM) }`
> via `rails console`, ou recriar o banco.

---

## 8. Atualizando a versão do Chatwoot no futuro

Esse patch foi calibrado **especificamente para o Chatwoot 4.13.0**. Para
subir versão:

1. Confirme que estes símbolos ainda existem na nova imagem:
   - `ChatwootHub.pricing_plan`
   - `Internal::ReconcilePlanConfigService#perform`
   - `Account#enable_features`, `Account#feature_enabled?`
2. Compare a constante `PREMIUM_PLAN_FEATURES` no `zz_unlock_enterprise.rb`
   com `enterprise/app/services/enterprise/billing/reconcile_plan_features_service.rb`
   da versão nova (extrair com `docker cp` igual ao processo desta versão).
3. Teste em ambiente isolado antes de subir em produção.

---

## 9. Princípios de design

- **Single source of truth**: tudo num único arquivo Ruby (~155 linhas).
- **Zero substituição de upstream**: monkey-patch em runtime, nada do código
  oficial é sobrescrito.
- **Idempotente**: rodar várias vezes não causa duplicação nem efeitos
  colaterais.
- **Fail-safe**: se algo dá errado no boot, é logado em `WARN` mas nunca
  derruba o Rails.
- **Defesa em camadas**: 5 mecanismos independentes, qualquer 1 sozinho já
  desbloqueia. Os outros 4 cobrem failover.
- **Swarm-native**: usa `configs:`, o mecanismo oficial do Swarm para injetar
  arquivos pequenos. Não depende de bind mounts.
