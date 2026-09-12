# 🚀 ToggleMaster: Microservices & Cloud Architecture on AWS EKS

![Kubernetes](https://img.shields.io/badge/kubernetes-%23326ce5.svg?style=for-the-badge&logo=kubernetes&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-%23FF9900.svg?style=for-the-badge&logo=amazon-aws&logoColor=white)
![Docker](https://img.shields.io/badge/docker-%230db7ed.svg?style=for-the-badge&logo=docker&logoColor=white)
![Postgres](https://img.shields.io/badge/postgres-%23316192.svg?style=for-the-badge&logo=postgresql&logoColor=white)
![Redis](https://img.shields.io/badge/redis-%23DD0031.svg?style=for-the-badge&logo=redis&logoColor=white)

## 📌 Visão Geral do Projeto
O **ToggleMaster** é uma plataforma distribuída de gerenciamento de Feature Flags e segmentação de usuários. Este projeto documenta a evolução arquitetural do sistema, que transitou de um MVP monolítico para um ecossistema nativo de nuvem (Cloud-Native) orquestrado com **Kubernetes (Amazon EKS)**.

O foco principal desta implementação é a **resiliência, alta disponibilidade e escalabilidade elástica**, resolvendo desafios práticos de engenharia de infraestrutura, roteamento interno e isolamento de redes virtuais.

---

## 🏗️ Arquitetura de Nuvem e DevOps

A infraestrutura foi desenhada e provisionada na AWS, separando as camadas de computação, armazenamento relacional, cache de alta velocidade e processamento assíncrono de dados.

### ⚙️ Orquestração e Redes
* **Amazon EKS (v1.34):** Cluster Kubernetes configurado via `eksctl` para gerenciamento elástico dos contêineres.
* **VPC Peering & Security Groups:** Roteamento de tráfego seguro interligando a malha de rede isolada do cluster K8s (`192.168.x.x`) com a infraestrutura legada de Data Stores (`10.0.x.x`).
* **Nginx Ingress Controller:** Ponto único de entrada atuando em conjunto com o AWS Load Balancer para roteamento inteligente (Path-based routing).
* **CoreDNS:** Comunicação interna direta entre os microsserviços, garantindo latência próxima a zero sem exposição pública.

### 📊 Data Stores e Mensageria
* **Amazon RDS (PostgreSQL):** Persistência relacional com consistência ACID para os serviços core (`auth`, `flag`, `targeting`).
* **Amazon ElastiCache (Redis):** Cache em memória focado em performance extrema para o *hot path* de validação de flags.
* **Amazon DynamoDB & AWS SQS:** Pipeline de dados desacoplado, onde eventos de avaliação são enfileirados no SQS e consumidos de forma assíncrona para persistência analítica no DynamoDB.

---

## 🧩 O Ecossistema de Microsserviços

O sistema foi decomposto em 5 microsserviços independentes, conteinerizados com Docker (Multi-stage builds):

1. 🔐 **Auth Service (Go):** Gerenciamento de chaves de API e validação de acesso.
2. 🚩 **Flag Service (Python):** CRUD e modelagem estrutural das Feature Flags.
3. 🎯 **Targeting Service (Python):** Motor de regras complexas para segmentação de usuários.
4. ⚡ **Evaluation Service (Go):** Microsserviço de alta performance. Consulta o Redis para retornar decisões de ativação em milissegundos e produz eventos analíticos.
5. 📈 **Analytics Service (Python):** *Worker* focado em análise de dados. Consome a fila do SQS e persiste métricas no DynamoDB para posterior exploração e BI.

---

## 📈 Escalabilidade Automática (HPA)

A arquitetura foi projetada para lidar com picos de tráfego de forma autônoma. Utilizando o **Metrics Server**, foram configurados `Horizontal Pod Autoscalers (HPA)`:
* O `evaluation-service` escala horizontalmente ao detectar picos de requisições externas na CPU.
* O `analytics-service` atua de forma elástica, multiplicando suas réplicas automaticamente à medida que o volume de mensagens na fila do SQS gera maior carga de processamento computacional.

---
