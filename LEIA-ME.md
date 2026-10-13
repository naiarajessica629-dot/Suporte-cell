# Suporte Remoto — site de espelhamento de tela

Site pronto onde você (atendente) gera um link, envia ao cliente, e vê a tela dele ao vivo pelo navegador. Um único servidor Node, **sem dependências** (não precisa de `npm install`).

## O que funciona hoje

- Página do atendente (`/`): gera o convite, mostra o link e QR, e exibe a tela recebida.
- Página do cliente (`/s/CODIGO`): pede a permissão do navegador e compartilha a tela.
- Transmissão **WebRTC real**, ponto a ponto, cifrada (DTLS-SRTP).
- Estatísticas ao vivo (latência, FPS, bitrate) lidas do próprio WebRTC.

## Limite importante (leia antes)

Navegadores de **celular** (Chrome Android, Safari iOS) **não** permitem compartilhar a própria tela. Então, por este site:

- **Computador do cliente** (Windows/Mac/Linux, no Chrome/Edge/Firefox): funciona 100%.
- **Celular do cliente**: não dá pelo navegador — precisa do app nativo (projeto Flutter, à parte). A página do cliente detecta o celular e avisa.

O atendente pode usar qualquer dispositivo para **assistir**.

## Rodar no seu computador (teste rápido)

Precisa de Node 18+ instalado.

```bash
node server.js
```

Abra `http://localhost:3000`. Para testar os dois lados, abra o link do cliente em outra aba/outro computador da mesma rede.

## Publicar na internet (ter um endereço fixo) — grátis

### Opção A — Render (recomendada)

1. Crie uma conta em https://render.com (grátis).
2. Suba esta pasta para um repositório no GitHub.
3. No Render: **New → Web Service → Build and deploy from a Git repository**.
4. Selecione o repositório. O arquivo `render.yaml` já configura tudo; ou preencha à mão:
   - Runtime: **Node**
   - Build Command: *(deixe vazio)*
   - Start Command: `node server.js`
   - Plan: **Free**
5. Deploy. Em ~1 minuto você recebe um endereço como `https://suporte-remoto.onrender.com`.

> O plano grátis do Render "dorme" após inatividade; a primeira abertura depois disso leva ~30s. Para uso constante, use o plano pago mais barato.

### Opção B — Railway

1. https://railway.app → **New Project → Deploy from GitHub repo**.
2. Start Command: `node server.js`. Railway define a porta sozinho (variável `PORT`, já tratada no código).

### Opção C — VPS própria (controle total)

Em um servidor com Node e um domínio apontado:

```bash
node server.js
```

Coloque um Nginx na frente com HTTPS (Let's Encrypt). **HTTPS é obrigatório** para o compartilhamento de tela funcionar fora de `localhost`.

## Login do atendente

O painel (`/`) agora pede usuário e senha. O link do cliente (`/s/CODIGO`) continua aberto, sem login.

Defina as credenciais nas variáveis de ambiente do Render (Settings → Environment):

```
ADMIN_USER=seu_usuario
ADMIN_PASS=sua_senha_forte
```

Enquanto não definir, vale o padrão `admin` / `suporte123` — troque assim que publicar. A sessão dura 12 horas.

## Rede corporativa (TURN)

Em ~10–20% das redes (NAT restrito), o vídeo não conecta só com STUN. Configure um servidor TURN e informe as variáveis de ambiente — o site as entrega ao navegador automaticamente:

```
TURN_URL=turn:seu-turn.exemplo.com:3478
TURN_USER=usuario
TURN_PASS=senha
```

TURN gratuito para começar: https://www.metered.ca/tools/openrelay/ (ou suba um `coturn` na sua VPS).

## Estrutura

```
server.js          servidor (HTTP + sinalização WebSocket), zero dependências
package.json       metadados e script de start
render.yaml        configuração de deploy no Render
public/
  index.html       painel do atendente
  cliente.html     página de compartilhamento do cliente
  app.js           lógica WebRTC dos dois lados
  estilo.css       estilo compartilhado
```

## Segurança (o que já tem e o que falta para produção)

Já incluído: link com código aleatório e validade; o servidor só repassa sinalização e nunca toca no vídeo; nenhum frame é gravado; proteção contra path traversal nos estáticos.

Para produção, acrescente: login do atendente (hoje qualquer um com o endereço abre o painel), sessões em Redis com expiração real em vez de memória, e registro de auditoria. O passo a passo está na especificação técnica do projeto.
