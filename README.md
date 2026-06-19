# Rifa Digital com Supabase

Sistema multi-vendedor para rifa digital com 100.000 numeros, vouchers 58mm, ranking e validacao por QR Code.

## O que esta versao faz

- Login por vendedor usando Supabase Auth.
- Todos os vendedores usam o mesmo banco de dados.
- Os numeros sao gerados no banco e nao repetem entre vendedores.
- Cada venda pode gerar varios vouchers para o mesmo cliente.
- O painel mostra numeros disponiveis, vendidos, faturamento e ranking dos vendedores.
- O dono/admin pode cadastrar vendedores pela tela do sistema.
- O dono/admin tem um painel separado com metricas, vendas por vendedor, vendas recentes e contatos autorizados para marketing.
- O cadastro do cliente inclui autorizacao opcional para campanhas futuras.
- O dono/admin pode configurar nome, premio, data do sorteio, valor por numero e texto de privacidade.
- O dono/admin pode cancelar vendas sem liberar os numeros para revenda.
- O dono/admin pode exportar ranking, vendas, contatos e backup JSON.
- Cada voucher tem QR Code com token assinado.
- A validacao consulta o Supabase e registra a tentativa no banco.
- Impressao preparada para cupom de 58mm.

## Arquivos principais

- `index.html`: telas do aplicativo.
- `styles.css`: layout e impressao 58mm.
- `app.js`: login, emissao, ranking, validacao e impressao.
- `config.js`: URL e chave anonima do Supabase.
- `supabase/schema.sql`: tabelas, politicas, ranking e funcoes do banco.
- `supabase/admin-upgrade.sql`: atualizacao para painel ADM e consentimento de marketing.
- `supabase/commercial-upgrade.sql`: cancelamento, configuracoes da rifa, relatorios, backup e LGPD operacional.
- `supabase/first-owner.sql`: cria o primeiro dono da rifa.
- `supabase/functions/admin-create-seller/index.ts`: Edge Function para cadastrar vendedores.

## Como configurar o Supabase

1. Crie um projeto no Supabase.
2. Abra o SQL Editor e rode `supabase/schema.sql`.
3. Em Authentication > Users, crie o usuario do dono da rifa.
4. Copie o UUID desse usuario.
5. Edite e rode `supabase/first-owner.sql`.
6. Publique a Edge Function `admin-create-seller`.
7. Em `config.js`, coloque:
   - `url`: Project URL do Supabase.
   - `anonKey`: anon public key do Supabase.
8. Abra `index.html` e entre com o email/senha do dono.

## Seguranca

O navegador nunca gera numeros sozinho. A funcao `issue_vouchers` roda no banco, usa trava transacional e a tabela `vouchers` tem chave unica em `(raffle_id, ticket_number)`. Mesmo se dois vendedores venderem ao mesmo tempo, o banco impede numero duplicado.

O QR Code pode ser lido por qualquer camera, mas ele contem apenas um token assinado. A validacao real depende da funcao `validate_voucher_token` no Supabase.

## Primeiro teste

Depois de entrar como dono:

1. Cadastre um vendedor.
2. Saia e entre com o vendedor.
3. Emita uma venda com quantidade maior que 1.
4. Imprima os vouchers.
5. Copie o token de um voucher e valide na aba Validar.
6. Veja o ranking atualizar.

## Atualizacao do painel ADM

Se o banco ja foi criado antes desta versao, rode `supabase/admin-upgrade.sql` no SQL Editor do Supabase antes de publicar o site atualizado na Vercel.

O painel ADM usa a funcao `get_admin_dashboard`, entao ela precisa existir no Supabase para o administrador entrar sem erro.

## Atualizacao comercial

Rode `supabase/commercial-upgrade.sql` no SQL Editor do Supabase para habilitar:

- cancelamento de vendas;
- logs de auditoria;
- configuracoes da rifa pelo ADM;
- exportacao de backup;
- remocao de contatos das campanhas.

Por seguranca, venda cancelada nao libera os numeros para revenda. Isso preserva a auditoria e evita repeticao de numero.
