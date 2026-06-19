# Rifa Digital com Supabase

Sistema multi-vendedor para rifa digital com até 100.000 números, vouchers 58mm, ranking, painel ADM e validação por QR Code.

## O que esta versão faz

- Login por vendedor usando Supabase Auth.
- Todos os vendedores usam o mesmo banco de dados.
- Os números são gerados no banco e não repetem entre vendedores.
- Cada venda pode gerar vários vouchers para o mesmo cliente.
- O vendedor escolhe qual rifa ativa vai vender antes de emitir vouchers.
- O dono/admin pode criar várias rifas com foto enviada do computador, descrição do prêmio, valor, quantidade e data do sorteio.
- O dono/admin tem painel separado com métricas, vendas por vendedor, vendas recentes e contatos autorizados para marketing.
- O cadastro do cliente inclui autorização opcional para campanhas futuras.
- O dono/admin pode cancelar vendas sem liberar os números para revenda.
- O dono/admin pode exportar ranking, vendas, contatos e backup JSON.
- Cada voucher tem QR Code com token assinado.
- A validação consulta o Supabase e registra a tentativa no banco.
- No celular, a validação também pode ler o QR Code pela câmera.
- Impressão preparada para cupom de 58mm.

## Arquivos principais

- `index.html`: telas do aplicativo.
- `styles.css`: layout e impressão 58mm.
- `app.js`: login, emissão, ranking, validação, câmera QR e impressão.
- `config.js`: URL e chave anônima do Supabase.
- `supabase/schema.sql`: tabelas, políticas, ranking e funções do banco.
- `supabase/admin-upgrade.sql`: atualização para painel ADM e consentimento de marketing.
- `supabase/commercial-upgrade.sql`: cancelamento, configurações da rifa, relatórios, backup e LGPD operacional.
- `supabase/multi-raffle-upgrade.sql`: várias rifas ativas, seleção de campanha e criação de rifas pelo ADM.
- `supabase/storage-upgrade.sql`: bucket do Supabase Storage para upload da imagem da rifa.
- `supabase/reset-database.sql`: limpa rifas, vendas, vouchers e imagens para recomeçar do zero.
- `supabase/first-owner.sql`: cria o primeiro dono da rifa.
- `supabase/functions/admin-create-seller/index.ts`: Edge Function para cadastrar vendedores.

## Ordem para configurar no Supabase

1. Crie um projeto no Supabase.
2. Abra o SQL Editor e rode `supabase/schema.sql`.
3. Rode `supabase/admin-upgrade.sql`.
4. Rode `supabase/commercial-upgrade.sql`.
5. Rode `supabase/multi-raffle-upgrade.sql`.
6. Rode `supabase/storage-upgrade.sql`.
7. Em Authentication > Users, crie o usuário do dono da rifa.
8. Copie o UUID desse usuário.
9. Edite e rode `supabase/first-owner.sql`.
10. Publique a Edge Function `admin-create-seller`.
11. Em `config.js`, coloque a Project URL e a anon public key do Supabase.
12. Publique os arquivos na Vercel.

## Começar do zero

Para zerar as rifas de teste, rode `supabase/reset-database.sql` no SQL Editor.

Esse reset apaga rifas, clientes, vendas, vouchers, validações, logs e imagens enviadas, mas mantém usuários e vendedores/admins para você conseguir entrar novamente.

Depois do reset, entre como admin e crie uma nova rifa pelo painel.

## Segurança

O navegador nunca gera números sozinho. A função `issue_vouchers` roda no banco, usa trava transacional e a tabela `vouchers` tem chave única em `(raffle_id, ticket_number)`. Mesmo se dois vendedores venderem ao mesmo tempo, o banco impede número duplicado.

O QR Code contém um token assinado. A validação real depende da função `validate_voucher_token` no Supabase, por isso o sistema consegue consultar se o voucher existe, qual número pertence a ele e se já foi validado.

Por segurança, venda cancelada não libera os números para revenda. Isso preserva a auditoria e evita repetição de número.
