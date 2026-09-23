# Sergey Khanov, Software Development Engineer

## PROFESSIONAL SUMMARY

Goal-oriented Software Development Engineer with over 15 years of IT experience, currently working on Intapp's Employee Compliance SaaS platform for regulated financial firms and on Intapp's Reporting Service, which provides BI reporting for Intapp products. Expert in Java and proficient in the Spring ecosystem: Spring Boot, Spring MVC, Spring WebFlux, Spring Security, Spring Data, Spring Integration, and Spring Cloud. Rich experience in designing, implementing, and deploying microservices with REST, gRPC, and messaging (Apache Kafka, ActiveMQ). Strong knowledge of PostgreSQL and Microsoft SQL Server, with hands-on experience in Redis, DynamoDB, MongoDB, and OpenSearch. Experienced with AWS and Azure, including an AWS-to-Azure migration, and with deploying to Kubernetes via Helm and Argo CD (GitOps). Supports production services across multiple regions, with monitoring based on Prometheus, OpenTelemetry, and Grafana. Ensures quality with automated unit, integration, E2E, smoke, and regression tests. Experienced in integrating products with BI platforms (Sisense, Power BI) and external data providers (FactSet, Plaid). Also works as a full-stack TypeScript developer, building services with Node.js, Express, and NestJS and UIs with Angular and React. Solid system administration background. Strong communication and collaboration skills.

## TECHNOLOGY SUMMARY

| Area | Technologies |
|---|---|
| **Languages** | Java, Groovy, Python, JavaScript (ECMAScript), TypeScript, HTML5, CSS3, SQL |
| **Backend** | Java SE, Spring Framework, Spring Boot, Spring MVC, Spring WebFlux, Spring Security, Spring Integration, Spring Cloud (Netflix OSS, Stream), Spring AOP, Spring Data (Spring JDBC, Spring Data JPA, Hibernate), MapStruct, Swagger/OpenAPI, Node.js, Express, NestJS, TypeORM, Agenda.js, Serverless Framework, Flask, PyTorch |
| **Security** | OAuth 2.0, OpenID Connect, JWT, Keycloak, Auth0, Microsoft Entra ID |
| **Frontend** | React, Redux, Angular, Nx, Bootstrap, Material UI, PrimeNG |
| **Databases and Search** | PostgreSQL, MySQL, Microsoft SQL Server, MongoDB, Redis, Amazon DynamoDB, Amazon Redshift, Elasticsearch, OpenSearch, Liquibase |
| **Testing** | JUnit 5, Mockito, Spring Test, Testcontainers, WireMock, TestNG, Cucumber, Selenide, Jest, Jasmine |
| **Observability** | Micrometer, Prometheus, OpenTelemetry, Grafana, Kibana |
| **Containers and Orchestration** | Docker, Docker Compose, Kubernetes (Helm charts, Argo CD), Docker Swarm |
| **Cloud** | Azure (Blob Storage, Key Vault, DNS, Functions, Virtual Machines), AWS (Lambda, EC2, ECS, EMR, RDS, S3, DynamoDB, Redshift, Route 53), GCP (Compute Engine) |
| **CI/CD** | GitLab CI, Jenkins, Azure DevOps (Pipelines), Argo CD (GitOps) |
| **APIs and Messaging** | REST, gRPC, Apache Kafka, ActiveMQ |
| **Data Processing** | Apache Spark, Kafka Streams |
| **BI and Integrations** | Sisense, Power BI, FactSet, Plaid, Microsoft Graph |
| **Build Tools** | Gradle, Maven, npm, Webpack |
| **Version Control** | Git |
| **Other** | OOP and functional programming, GoF design patterns, UML, Agile, Linux, Windows Server, Bash and Python scripting, MinIO, Vagrant, IntelliJ IDEs, Visual Studio Code |

## KEY TECHNICAL SKILLS

**Backend development**

- Languages: Java, Groovy, Python, TypeScript, SQL
- Frameworks: Java SE, Spring Framework, Spring Boot, Spring MVC, Spring WebFlux, Spring Security, Spring Integration, Spring Cloud (Netflix OSS, Stream), Spring AOP, Spring Data (Spring JDBC, Spring Data JPA, Hibernate), MapStruct, Swagger/OpenAPI, Node.js, Express, NestJS, TypeORM, Agenda.js, Serverless Framework, Flask, PyTorch
- APIs and messaging: REST, gRPC, Apache Kafka, ActiveMQ
- Data processing: Apache Spark, Kafka Streams
- Security: OAuth 2.0, OpenID Connect, JWT, Keycloak, Auth0, Microsoft Entra ID
- Testing: JUnit 5, Mockito, Spring Test, Testcontainers, WireMock, TestNG, Cucumber, Selenide, Jest

**Frontend development**

- Languages: JavaScript (ECMAScript), TypeScript, HTML5, CSS3
- Frameworks and libraries: React, Redux, Angular, Nx, Bootstrap, Material UI, PrimeNG
- Testing: Jest, Jasmine

**Databases and search**

- PostgreSQL, MySQL, Microsoft SQL Server, MongoDB, Redis, Amazon DynamoDB, Amazon Redshift, Elasticsearch, OpenSearch
- Schema migrations: Liquibase

**DevOps**

- Containers and orchestration: Docker, Docker Compose, Kubernetes (Helm charts, Argo CD), Docker Swarm
- Cloud: Azure (Blob Storage, Key Vault, DNS, Functions, Virtual Machines), AWS (Lambda, EC2, ECS, EMR, RDS, S3, DynamoDB, Redshift, Route 53), GCP (Compute Engine)
- CI/CD: GitLab CI, Jenkins, Azure DevOps (Pipelines), Argo CD (GitOps)
- Observability: Micrometer, Prometheus, OpenTelemetry, Grafana, Kibana
- Build tools and version control: Gradle, Maven, npm, Webpack, Git

**BI and integrations**

- Sisense, Power BI, FactSet, Plaid, Microsoft Graph

**Other**

- OOP and functional programming, GoF design patterns, UML, Agile, Linux, Windows Server, Bash and Python scripting, MinIO, Vagrant, IntelliJ IDEs, Visual Studio Code

## PROFESSIONAL EXPERIENCE

### Akvelon

**Software Development Engineer** | December 2019 – present

#### Intapp Employee Compliance

A multi-tenant SaaS employee compliance platform for regulated financial firms: personal-trade pre-clearance, brokerage-account monitoring, restricted-list surveillance, attestations, and compliance-officer review workflows. Forms, validation, workflows, emails, and dashboards are configured per tenant.

Main components:

- **Core platform** – Spring Boot backend services (disclosures app server, event handler, external API, scheduled jobs, data services), tenant/cluster provisioner, and Angular (Nx) UI
- **Rules Engine** – Node.js/TypeScript service that runs on AWS Lambda (Serverless) and as an Express API on Azure; it loads brokerage accounts, holdings, and transactions, checks trades and holdings against restriction rules, raises trade alerts, and syncs data to OpenSearch
- **Security Master API** – Node.js/TypeScript/Express service for security, entity, and broker search and lookup, custom securities, and pre-clearance checks over FactSet reference data in PostgreSQL
- **Helm charts and Argo CD applications** – GitOps-based deployment to Kubernetes

Main achievements and responsibilities:

- Developed features across Java backend services, Node.js/TypeScript services, and the Angular UI
- Implemented trade and holdings processing, restriction checks, and trade alerts in the Rules Engine
- Developed security search, lookup, and pre-clearance endpoints in the Security Master API; migrated FactSet reference data from Redshift to PostgreSQL with scheduled pg_cron refreshes
- Worked with PostgreSQL (Liquibase migrations), Redis (caching, ShedLock-based job locking), Kafka event processing, and OpenSearch
- Integrated with Intapp platform services, Auth0, Plaid (brokerage accounts), FactSet, and Microsoft Graph
- Implemented tenant provisioning and per-tenant JSON configuration stored in Azure Blob Storage
- Covered services with unit and integration tests (JUnit 5, Mockito, Testcontainers, WireMock, Jest)
- Deployed to Kubernetes with Helm and Argo CD (GitOps) and to AWS Lambda; added monitoring with Micrometer, Prometheus, OpenTelemetry, and Grafana

Technologies: Java 21, TypeScript, Node.js, SQL, Spring Boot, Spring Data JPA, Spring Kafka, MapStruct, Express, Serverless Framework, Angular, Nx, PostgreSQL, pg_cron, Liquibase, Redis, Apache Kafka, OpenSearch, AWS (Lambda, STS, Redshift), Azure (Blob Storage, Key Vault, Entra ID), Kubernetes, Helm, Argo CD, Docker, Jenkins, Gradle, OpenAPI (springdoc), Auth0, JWT, Plaid, FactSet, Microsoft Graph, JUnit 5, Mockito, Testcontainers, WireMock, Jest, Micrometer, Prometheus, OpenTelemetry, Grafana

---

#### Intapp Reporting Service

A set of services that make data from Intapp products (Pricing, Time, Open, and others) available in Sisense and Power BI, and manage reporting resources for each tenant across regional clusters.

Main components:

- **Reporting Service** – Spring Boot backend: REST API, PostgreSQL, and messaging
- **Provision Service** – tenant provisioning through Intapp's tenant management and identity services: cloud resources, DNS, and secrets
- **UI and BI** – Angular Reporting UI, Power BI service with a React UI, and Sisense templates with automated validation
- **Availability tests, Helm charts, and Argo CD applications** – synthetic monitoring and GitOps-based deployment to Kubernetes

Main achievements and responsibilities:

- Designed PostgreSQL databases (Liquibase migrations), the REST API (OpenAPI), and Kafka messaging (Spring Cloud Stream) between the reporting services and the platform
- Implemented tenant provisioning and deprovisioning with Intapp platform services (tenant management, identity management, Keycloak)
- Developed features and maintained backend services and UI applications
- Covered services with unit, integration, E2E, smoke, regression, and synthetic availability tests
- Supported production in 4 regions (US, CA, EU, APAC) and resolved incidents together with the Product and Platform teams
- Migrated cloud services from AWS (RDS, DynamoDB, S3, EC2, Route 53) to Azure (Blob Storage, Key Vault, DNS, Entra ID with MSAL, Functions, Virtual Machines)
- Deployed to Kubernetes with Helm and Argo CD (GitOps); added monitoring with Micrometer, Prometheus, and Grafana

Technologies: Java, Groovy, TypeScript, SQL, Python, Linux, Bash, Spring Boot, Spring Data JPA, Spring MVC, Spring WebFlux, Spring Security, Spring Integration, Spring Cloud Stream, Spring AOP, Angular, React, PostgreSQL, Microsoft SQL Server, Liquibase, Apache Kafka, ActiveMQ, AWS (RDS, DynamoDB, S3, EC2, Route 53), Azure (Blob Storage, Key Vault, DNS, Entra ID, Functions, Virtual Machines), Azure DevOps, GCP, Kubernetes, Helm, Argo CD, Docker, Git, Jenkins, MinIO, REST, OpenAPI, gRPC, Maven, Gradle, TestNG, Selenide, Micrometer, Prometheus, Grafana, Kibana, OAuth 2.0, OpenID Connect, Keycloak, Swagger, Sisense, Power BI, IntelliJ IDEA Ultimate

---

#### DeliverHealth Automatic Speech Recognition SaaS Cloud

ASR (automatic speech recognition) Cloud is part of a medical transcription workflow: a service for voice dictation, transcription, and speech recognition with a healthcare-specific knowledge base. ASR Cloud has two main workflows: draft generation and model building.

Main achievements and responsibilities:

- Designed, migrated, and maintained Microsoft SQL Server and PostgreSQL databases
- Designed microservices following DeliverHealth's strict conventions; created and updated microservice design specifications in UML
- Designed REST and gRPC APIs and messaging between microservices
- Developed new microservices and features for the draft generation workflow and maintained existing ones
- Developed a new serverless application with Azure Functions
- Covered services with unit, integration, and UAT tests (microservices deployed in isolated Docker containers with mocks in the local environment)
- Traced microservice logs in Kibana, debugged microservices in the Kubernetes cluster, and fixed bugs caused by implementation errors and by version mismatches between services and libraries
- Tested the end-to-end draft generation workflow, from audio file upload to saving the transcription to an Azure Storage account
- Prepared Helm charts and deployed services to Kubernetes

Technologies: Java, SQL, Python, Linux, Bash, Spring Boot, Spring Data, PostgreSQL, Microsoft SQL Server, Azure DevOps, Azure (Storage accounts, Functions, Virtual Machines), GCP, ActiveMQ, Kubernetes, Docker, Git, Jenkins, Kibana, MinIO, REST, gRPC, Maven, Gradle, TestNG, Cucumber, IntelliJ IDEA Ultimate

---

#### Intapp Pricing

An automated scoping and pricing tool that uses data science to deliver value-based price proposals that are attractive to clients and profitable for firms. The product is a cloud web application made up of multiple services running in Docker containers on Kubernetes. It includes a Kafka-based data pipeline that provides reliable, reconcilable storage of financial data.

Main achievements and responsibilities:

- Owned database design and maintenance on PostgreSQL
- Managed database migrations with Liquibase
- Developed new features and maintained the Angular UI
- Developed new features and maintained the Spring backend microservices
- Covered all related services with unit, integration, and E2E tests
- Collaborated with other teams to improve shared services
- Handled client-reported incidents
- Investigated production alerts in Grafana
- Analyzed Kibana logs to prevent production issues

Technologies: Java, TypeScript, JavaScript, SQL, HTML5, CSS3, Python, Bash, Spring Boot, Spring Cloud (Netflix OSS), Spring Data JPA, Hibernate, Angular, Bootstrap, PrimeNG, Liquibase, PostgreSQL, Elasticsearch, Apache Kafka, Kafka Streams, Apache Spark, AWS (ECS, EC2, EMR, RDS, S3), Kubernetes, Docker, Git, Jenkins, Vagrant, Grafana, Kibana, Swagger, IntelliJ IDEA Ultimate, WebStorm

---

#### LinkedIn Search Tool

A middleware web application for LinkedIn that finds people by showing every possible connection path from the user's account to them. The application manages accounts, runs searches, shows detailed profile information, and generates reports on the people being searched for.

Main achievements and responsibilities:

- Designed the MongoDB database and its migrations
- Maintained the application: bug fixes, refactoring, and new features
- Developed scheduled jobs with Agenda.js
- Developed new UI features in React
- Developed new backend features in Node.js

Technologies: JavaScript, TypeScript, React, Redux, Node.js, Agenda.js, Webpack, Material UI, MongoDB, Docker, Git, GitLab, Jest, Jasmine, Visual Studio Code

---

#### Akvelon AI Distal Radius Fracture Recognition

An internal Akvelon project that classifies and locates distal radius fractures in uploaded wrist X-ray images. The project consists of a web API service that hosts the computer vision models and a web portal that shows the image processing results. The model is built from three deep convolutional neural networks: the first classifies images as X-ray or non-X-ray, the second classifies the fracture type (Smith, Colles, Barton, or no fracture), and the third detects the fracture location. The result contains the fracture type and its location.

Main achievements and responsibilities:

- Implemented the web portal and a demo of the service features in React
- Implemented the web API service hosting the ML models

Technologies: Python, PyTorch, Flask, JavaScript, TypeScript, React, Docker

---

#### Akvelon Case Study Platform

A web application that keeps all case studies (short descriptions of delivered projects and the customer outcomes achieved with Akvelon) in one place. It lets sales, account, business development, technical, and marketing managers create new case studies easily and share them with customers quickly through a customized website or email.

Main achievements and responsibilities:

- Owned the MySQL database design and migrations
- Developed UI components with React and related libraries
- Implemented REST communication between the frontend and backend
- Implemented the backend service with NestJS
- Implemented the backend ORM layer with TypeORM
- Built GitLab CI/CD pipelines to test and deliver the services
- Deployed the services to Akvelon's Kubernetes cluster and to a GCP Compute Engine VM with Docker Swarm

Technologies: JavaScript, TypeScript, React, Node.js, NestJS, TypeORM, MySQL, HTML5, CSS3, Material UI, Docker, Docker Compose, Docker Swarm, Kubernetes, GCP Compute Engine, GitLab CI, npm, Jest, Jasmine

---

### Argo-Expert

**Software Development Engineer, System Administrator** | July 2017 – November 2019

Main achievements and responsibilities:

- Designed, configured, and maintained the company LAN
- Configured and maintained servers
- Administered the domain, mail, firewall, antivirus, VPN for remote stores, 1C, and Bitrix24
- Developed an Angular SPA that extended the sales department's tools
- Developed Java applications that improved internal processes: a service that captured photos from security cameras, and an Android application (based on the osmdroid library) that measured agricultural field areas using a polygon library and sent the results to the company's GIS server

Technologies: Java SE, JavaScript, Angular, Android, osmdroid, npm, 1C, Bitrix24

---

### PK Aquarius

**System Administrator** | June 2008 – July 2017

Main achievements and responsibilities:

- Configured and maintained the factory LAN (routers, switches, VLANs, access points)
- Assembled, configured, and maintained servers, PCs, and other hardware (testing, RAID setup, fault diagnosis, service recovery)
- Deployed, migrated, configured, and maintained network services, mainly on Windows Server (ISA Server, Active Directory, DHCP, DNS, WDS, Exchange, Microsoft SQL Server) and partly on Linux (LAMP with Joomla, ejabberd, Moodle, SIP telephony), including backup solutions
- Provided technical support to users across the organization

Technologies: Windows Server, Active Directory, Exchange, Microsoft SQL Server, Linux, LAMP, Joomla, ejabberd, Moodle, SIP telephony

## EDUCATION

**Specialist's Degree in Geography and Biology** | Ivanovo State University
