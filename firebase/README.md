# Firebase - Infraestrutura do Syncode

Esta pasta contém apenas as configurações de infraestrutura do Firebase para o repositório.
**Importante:** Nenhuma credencial ou secret deve ser incluída nesta pasta.

## Arquivos

- `firebase.json` — configuração do projeto Firebase, emulators, Firestore etc.
- `firestore.rules` — regras de segurança do banco.
- `firestore.indexes.json` — índices necessários no Firestore.

## Executando localmente

Para emular o ambiente do Firebase localmente durante o desenvolvimento:

1. Certifique-se de ter o Firebase CLI instalado:
   ```bash
   npm install -g firebase-tools
   ```

2. Na raiz do projeto, inicie os emuladores:
   ```bash
   firebase emulators:start
   ```
