#!/bin/bash

# Définition des dossiers et fichiers
OUTPUT_DIR="/output"
LOG_FILE="/output/conversion.log"
ERROR_LOG_FILE="/output/error.log"
mkdir -p "$OUTPUT_DIR"

# Initialisation des fichiers de log
echo "=== Démarrage de la conversion $(date) ===" > "$LOG_FILE"
echo "=== VERSION: 1.1.0 ===" >> "$LOG_FILE"
echo "=== Erreurs de conversion $(date) ===" > "$ERROR_LOG_FILE"

# Fonction de journalisation
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ERROR: $message" | tee -a "$ERROR_LOG_FILE" | tee -a "$LOG_FILE"
}

log_command() {
    local cmd="$1"
    log "COMMANDE: $cmd"
}

# Fonction pour vérifier l'espace disque
check_disk_space() {
    local dir="$1"
    local space=$(df -h "$dir" | awk 'NR==2 {print $4}')
    local percent=$(df -h "$dir" | awk 'NR==2 {print $5}')
    log "Espace disque disponible sur $dir: $space ($percent utilisé)"
    
    # Alerte si moins de 5% d'espace disponible
    local percent_num=$(df "$dir" | awk 'NR==2 {print $5}' | sed 's/%//')
    if [ "$percent_num" -gt 95 ]; then
        log_error "ALERTE: Espace disque faible sur $dir ($percent utilisé)!"
    fi
}

# On définit une fonction pour convertir les fichiers
convert_file() {
    local input_file="$1"
    local output_file="$2"
    
    log "Conversion du fichier: $(basename "$input_file")"
    
    # Vérification des droits d'accès
    if [ ! -r "$input_file" ]; then
        log_error "Impossible de lire le fichier source: $input_file"
        return 1
    fi
    
    # Détection du format vidéo avec gestion d'erreur
    local video_codec
    video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
    
    if [ -z "$video_codec" ]; then
        log_error "Impossible de détecter le codec vidéo pour $input_file"
        return 1
    fi
    
    log "Codec détecté: $video_codec"
    
    # Obtention de la durée de la vidéo pour calculer la progression
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
    
    if [ -z "$duration" ]; then
        log_error "Impossible de détecter la durée pour $input_file"
        duration=0
    else
        duration=${duration%.*} # On supprime la partie décimale
    fi
    
    # On récupère la fréquence d'images (framerate)
    local fps
    fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
    
    # Si le framerate est au format x/y, on fait le calcul
    if [[ $fps == *"/"* ]]; then
        local num=${fps%/*}
        local den=${fps#*/}
        # On utilise awk à la place de bc (qui n'est pas disponible)
        fps=$(awk "BEGIN {printf \"%.2f\", $num / $den}")
    fi
    log "Framerate détecté: ${fps:-Unknown} fps"
    
    # Récupération d'autres infos
    local resolution audio_codec
    resolution=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$input_file" 2>> "$ERROR_LOG_FILE")
    audio_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
    log "Résolution: ${resolution:-Unknown}, Audio: ${audio_codec:-Aucun}"
    
    # Vérification de l'espace disponible
    check_disk_space "$OUTPUT_DIR"
    
    # Fonction pour afficher la barre de progression
    progress_bar() {
        local current_time=$1
        local current_fps=$2
        local percent=0
        
        if [ "$duration" -gt 0 ]; then
            percent=$((current_time * 100 / duration))
        fi
        
        # Limiter à 100%
        if [ $percent -gt 100 ]; then
            percent=100
        fi
        
        # Construire la barre de progression
        local bar_length=50
        local completed=$((percent * bar_length / 100))
        local remaining=$((bar_length - completed))
        
        local progress_bar="["
        for ((i=0; i<completed; i++)); do
            progress_bar+="="
        done
        
        if [ $completed -lt $bar_length ]; then
            progress_bar+=">"
            remaining=$((remaining - 1))
        fi
        
        for ((i=0; i<remaining; i++)); do
            progress_bar+=" "
        done
        
        progress_bar+="] $percent%"
        
        # Calcul du temps restant estimé
        local eta="N/A"
        if [ $current_time -gt 0 ] && [ $current_fps -gt 0 ] && [ $duration -gt 0 ]; then
            local remaining_seconds=$((duration - current_time))
            eta=$((remaining_seconds / current_fps))
        fi
        
        # Affichage sur la même ligne en écrasant le contenu précédent
        echo -ne "\r$progress_bar Temps: $current_time/${duration:-?} s | FPS: $current_fps | ETA: ${eta}s"
    }
    
    # Création d'un fichier temporaire pour les erreurs
    local temp_error_file="/tmp/ffmpeg_error_$$.log"
    
    # Optimisation des permissions temporaires pour le fichier de sortie
    # Création du répertoire avec les bonnes permissions si nécessaire
    mkdir -p "$(dirname "$output_file")"
    touch "$output_file" # Créer le fichier vide pour s'assurer que les permissions sont bonnes
    chmod 777 "$output_file" # S'assurer que tout le monde peut écrire
    
    # Test d'écriture dans le dossier de sortie
    local test_file="$OUTPUT_DIR/test_write_$$.tmp"
    if ! touch "$test_file" 2> /dev/null; then
        log_error "Impossible d'écrire dans le dossier de sortie: $OUTPUT_DIR"
        return 1
    fi
    rm -f "$test_file"
    
    # Options de base communes aux deux méthodes
    local common_opts=(-map 0:v:0 -map 0:a:0? -sn
                      -c:v h264_nvenc -preset p4 -profile:v main -level 4.1 -b:v 2M -maxrate 2.5M -bufsize 5M 
                      -c:a aac -b:a 192k -ac 2 
                      -movflags +faststart 
                      -metadata:s:v language=und -metadata:s:a language=und 
                      -map_chapters -1 
                      -y # Force l'écrasement des fichiers existants
                      -f mp4)
    
    # Construction et journalisation des commandes
    local ffmpeg_cmd=""
    local conversion_success=0
    local error_output=""
    
    # Conversion avec différentes options selon le codec source
    if [[ "$video_codec" == "vp9" || "$video_codec" == "vp8" ]]; then
        log "⚠️ Codec VP8/VP9 détecté - utilisation du décodage logiciel"
        ffmpeg_cmd="ffmpeg -v warning -i \"$input_file\" ${common_opts[*]} \"$output_file\""
        log_command "$ffmpeg_cmd"
        
        # On lance ffmpeg avec la fonction de progression
        ffmpeg -v warning -i "$input_file" "${common_opts[@]}" -progress pipe:1 "$output_file" 2> "$temp_error_file" | \
        while read line; do
            # Journalisation des fps et autres indicateurs
            if [[ "$line" == "fps="* ]]; then
                echo "$line" >> "$LOG_FILE"
            fi
            
            # Extraction du temps écoulé
            if [[ "$line" == out_time_ms* ]]; then
                # Convertir les microsecondes en secondes
                current_time=$((${line#out_time_ms=} / 1000000))
                
                # Récupération du FPS actuel (solution simple)
                current_fps=1
                if [[ "$line" == *"fps="* ]]; then
                    current_fps=$(echo "$line" | grep -oP 'fps=\K[0-9]+')
                fi
                
                progress_bar $current_time $current_fps
            fi
        done
        echo # Nouvelle ligne après la barre de progression
    else
        # Accélération matérielle pour les autres codecs
        log "🚀 Utilisation de l'accélération GPU CUDA"
        ffmpeg_cmd="ffmpeg -v warning -hwaccel cuda -hwaccel_output_format cuda -i \"$input_file\" ${common_opts[*]} \"$output_file\""
        log_command "$ffmpeg_cmd"
        
        # Essayer avec l'accélération GPU
        ffmpeg -v warning -hwaccel cuda -hwaccel_output_format cuda -i "$input_file" "${common_opts[@]}" -progress pipe:1 "$output_file" 2> "$temp_error_file" | \
        while read line; do
            # Journalisation des fps et autres indicateurs
            if [[ "$line" == "fps="* ]]; then
                echo "$line" >> "$LOG_FILE"
            fi
            
            # Extraction du temps écoulé
            if [[ "$line" == out_time_ms* ]]; then
                # Convertir les microsecondes en secondes
                current_time=$((${line#out_time_ms=} / 1000000))
                
                # Récupération du FPS actuel (solution simple)
                current_fps=1
                if [[ "$line" == *"fps="* ]]; then
                    current_fps=$(echo "$line" | grep -oP 'fps=\K[0-9]+')
                fi
                
                progress_bar $current_time $current_fps
            fi
        done
        echo # Nouvelle ligne après la barre de progression
        
        # Si l'acceleration GPU a échoué, on essaie sans
        if [ ! -s "$output_file" ]; then
            log "⚠️ Échec de l'accélération GPU - tentative avec le décodage logiciel"
            ffmpeg_cmd="ffmpeg -v warning -i \"$input_file\" ${common_opts[*]} \"$output_file\""
            log_command "$ffmpeg_cmd"
            
            ffmpeg -v warning -i "$input_file" "${common_opts[@]}" -progress pipe:1 "$output_file" 2>> "$temp_error_file" | \
            while read line; do
                # Extraction du temps écoulé
                if [[ "$line" == out_time_ms* ]]; then
                    # Convertir les microsecondes en secondes
                    current_time=$((${line#out_time_ms=} / 1000000))
                    
                    # Récupération du FPS actuel (solution simple)
                    current_fps=1
                    if [[ "$line" == *"fps="* ]]; then
                        current_fps=$(echo "$line" | grep -oP 'fps=\K[0-9]+')
                    fi
                    
                    progress_bar $current_time $current_fps
                fi
            done
            echo # Nouvelle ligne après la barre de progression
        fi
    fi
    
    # Récupération des erreurs
    if [ -f "$temp_error_file" ]; then
        error_output=$(cat "$temp_error_file")
        if [ -n "$error_output" ]; then
            log_error "Erreurs ffmpeg pour $(basename "$input_file"):"
            log_error "$error_output"
        fi
        rm -f "$temp_error_file"
    fi
    
    # Vérification que le fichier a bien été créé et qu'il n'est pas vide
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        local filesize=$(du -h "$output_file" | cut -f1)
        log "✅ Conversion réussie: $(basename "$output_file") (${filesize})"
        # Journaliser les infos du fichier converti
        ffprobe -v error -hide_banner -of json -show_format -show_streams "$output_file" 2>/dev/null | tee -a "$LOG_FILE" > /dev/null
        return 0
    else
        log_error "❌ Échec de conversion pour: $(basename "$input_file")"
        if [ -f "$output_file" ]; then
            local filesize=$(du -h "$output_file" | cut -f1)
            log_error "Fichier de sortie existe mais problématique: ${filesize:-0 octets}"
            rm -f "$output_file"  # Supprimer le fichier vide ou corrompu
        fi
        return 1
    fi
}

# Fonction pour traiter un dossier
process_directory() {
    local input_dir="$1"
    
    log "🔍 Recherche de fichiers vidéo dans: $input_dir"
    
    # Compteurs pour le suivi
    local total_files=0
    local converted_files=0
    local failed_files=0
    
    # On stocke les fichiers dans un tableau pour éviter les doublons
    declare -A files_to_process
    
    # Vérification que le dossier d'entrée est lisible
    if [ ! -r "$input_dir" ]; then
        log_error "Le dossier d'entrée n'est pas accessible en lecture: $input_dir"
        return 1
    fi
    
    # On parcourt tous les formats vidéo courants
    for ext in mp4 mkv avi mov webm wmv flv ts m4v; do
        # On cherche les fichiers avec cette extension (correction pour éviter le doublon)
        for file in "$input_dir"/*.$ext; do
            # Vérifie si le fichier existe et n'est pas un wildcard non résolu
            if [ -f "$file" ] 2>/dev/null; then
                # On sauvegarde le chemin complet comme clé du tableau associatif
                # pour éviter les doublons
                files_to_process["$file"]=1
            fi
        done
    done
    
    # Affichage du nombre de fichiers trouvés
    total_files=${#files_to_process[@]}
    log "📋 Nombre total de fichiers trouvés: $total_files"
    
    # Vérification s'il y a des fichiers à traiter
    if [ $total_files -eq 0 ]; then
        log_error "Aucun fichier vidéo trouvé dans: $input_dir"
        log_error "Formats supportés: mp4, mkv, avi, mov, webm, wmv, flv, ts, m4v"
        return 1
    fi
    
    # Traitement des fichiers
    for file in "${!files_to_process[@]}"; do
        # On récupère le nom du fichier sans l'extension
        filename=$(basename -- "$file")
        basename="${filename%.*}"
        
        # On crée le chemin de sortie
        output_file="$OUTPUT_DIR/${basename}.mp4"
        
        # On vérifie si le fichier existe déjà
        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            log "⏩ Fichier déjà converti: $output_file"
            converted_files=$((converted_files + 1))
        else
            # On lance la conversion
            if convert_file "$file" "$output_file"; then
                converted_files=$((converted_files + 1))
            else
                failed_files=$((failed_files + 1))
            fi
        fi
    done
    
    log "📊 Résumé:"
    log "  - Total de fichiers trouvés: $total_files"
    log "  - Fichiers convertis avec succès: $converted_files"
    log "  - Échecs de conversion: $failed_files"
    
    if [ $failed_files -gt 0 ]; then
        log_error "Des échecs de conversion ont été rencontrés. Vérifiez le fichier $ERROR_LOG_FILE pour plus de détails."
        return 1
    fi
    
    return 0
}

# Point d'entrée principal
main() {
    local input_dir="/input"
    
    # Vérification que le dossier d'entrée existe
    if [ ! -d "$input_dir" ]; then
        log_error "❌ Erreur: Le dossier d'entrée $input_dir n'existe pas!"
        exit 1
    fi
    
    # Vérification que le dossier de sortie existe
    if [ ! -d "$OUTPUT_DIR" ]; then
        log "📁 Création du dossier de sortie: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
    fi
    
    # Vérification des permissions
    if [ ! -w "$OUTPUT_DIR" ]; then
        log_error "❌ Erreur: Le dossier de sortie $OUTPUT_DIR n'est pas accessible en écriture!"
        exit 1
    fi
    
    # Informations système
    log "🖥️ Informations système:"
    if command -v nvidia-smi &> /dev/null; then
        log "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'Non détecté')"
    else
        log "GPU: Non détecté (nvidia-smi non disponible)"
    fi
    
    log "🚀 Démarrage du processus de conversion pour IPTV"
    if ! process_directory "$input_dir"; then
        log_error "Des problèmes sont survenus pendant la conversion"
        exit 1
    fi
    log "✨ Toutes les conversions sont terminées!"
}

# Exécution du script
main "$@"