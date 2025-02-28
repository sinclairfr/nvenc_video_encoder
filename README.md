# 🎥 Encodeur Vidéo Segmenté avec NVIDIA NVENC

## 📝 Description du Projet

Ce projet propose un système robuste de transcodage vidéo par segments, optimisé pour l'utilisation de l'accélération GPU NVIDIA. L'outil est conçu pour convertir efficacement des fichiers vidéo de divers formats en MP4 h264, avec une gestion avancée de la reprise de conversion.

## ✨ Fonctionnalités Principales

- 🚀 Conversion vidéo accélérée par GPU
- 📦 Traitement par segments pour une grande flexibilité
- 🔄 Reprise automatique des conversions interrompues
- �録 Journalisation détaillée des opérations
- 🌈 Support de multiple formats d'entrée

## 🛠 Prérequis Techniques

- Docker
- Docker Compose
- Pilotes NVIDIA GPU
- NVIDIA Container Toolkit

## 🔧 Configuration

### Variables d'Environnement

Créez un fichier `.env` avec les paramètres suivants :

```
INPUT_FOLDER=/chemin/vers/dossier/source
OUTPUT_FOLDER=/chemin/vers/dossier/destination
```

### Structure des Dossiers

```
project/
│
├── docker-compose.yml       # Configuration Docker
├── convert_videos.sh        # Script principal de conversion
├── .env                     # Fichier de configuration
└── resume_state/            # Stockage de l'état de conversion
```

## 🚀 Démarrage Rapide

1. Clonez le dépôt
2. Configurez le fichier `.env`
3. Lancez la conversion :

```bash
docker-compose up
```

## 🔍 Détails Techniques

### Processus de Conversion

1. 📥 Détection automatique des fichiers vidéo
2. 🔪 Découpage en segments de 60 secondes
3. 🖥️ Transcodage avec accélération GPU
4. 🔗 Fusion des segments
5. 📤 Génération du fichier final MP4

### Gestion des Erreurs

- 📋 Journalisation complète dans `/output/conversion.log`
- ❌ Traces d'erreurs dans `/output/error.log`
- 🔁 Reprise possible des conversions interrompues

## ⚠️ Limitations Connues

- Nécessite un GPU NVIDIA compatible
- Performances variables selon la configuration matérielle
- Conversion uniquement vers h264

## 📋 Formats Supportés

- mp4
- mkv
- avi
- mov
- webm
- wmv
- flv
- ts
- m4v

## 🤝 Contribution

Les contributions sont les bienvenues ! Veuillez ouvrir une issue ou proposer une pull request.

## 📜 Licence

MIT License.

---

🚨 **Note Importante** : Ce script est fourni tel quel, sans garantie. Testez toujours sur un petit ensemble de fichiers avant un traitement massif.