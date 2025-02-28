#!/bin/bash

# Définition des dossiers et fichiers
OUTPUT_DIR="/output"
SEGMENTS_DIR="/output/segments"
RESUME_STATE_FILE="/input/resume_state.json"
LOG_FILE="/output/conversion.log"
ERROR_LOG_FILE="/output/error.log"
mkdir -p "$OUTPUT_DIR" "$SEGMENTS_DIR"

# Initialisation des fichiers de log
echo "=== Démarrage de la conversion $(date) ===" > "$LOG_FILE"
echo "=== VERSION: 1.3.0 ===" >> "$LOG_FILE"
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

# Fonction pour sauvegarder l'état de la conversion
save_state() {
    local file="$1"
    local segment_index="$2"
    local total_segments="$3"
    local output_file="$4"
    
    # Format JSON simple pour l'état
    cat > "$RESUME_STATE_FILE" << EOF
{
    "input_file": "$file",
    "output_file": "$output_file",
    "current_segment": $segment_index,
    "total_segments": $total_segments,
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    log "État sauvegardé: fichier $file, segment $segment_index/$total_segments"
}

# Fonction pour charger l'état précédent
load_state() {
    if [ -f "$RESUME_STATE_FILE" ]; then
        log "Fichier d'état trouvé, tentative de reprise..."
        return 0
    else
        return 1
    fi
}

# Fonction pour obtenir la durée d'une vidéo en secondes
get_video_duration() {
    local input_file="$1"
    
    # Obtention de la durée totale de la vidéo
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
    
    if [ -z "$duration" ]; then
        log_error "Impossible de détecter la durée pour $input_file"
        echo "0"
        return 1
    fi
    
    # Conversion en nombre entier (secondes)
    duration=${duration%.*}
    echo "$duration"
    return 0
}

# Fonction pour transcoder un segment
# Fonction pour transcoder un segment
transcode_segment() {
   local input_file="$1"
   local output_file="$2"
   local start_time="$3"
   local duration="$4"
   local segment_index="$5"
   local total_segments="$6"
   
   local segment_output="${output_file%.*}_segment_${segment_index}.mp4"
   
   log "Transcodage du segment $segment_index/$total_segments (début: ${start_time}s, durée: ${duration}s)"
   
   # Options de base communes
   local common_opts=(-ss "$start_time" -t "$duration"
                     -map 0:v:0 -map 0:a:0? -sn
                     -c:v h264_nvenc -preset p4 -profile:v main -level 4.1 -b:v 2M -maxrate 2.5M -bufsize 5M 
                     -c:a aac -b:a 192k -ac 2 
                     -movflags +faststart 
                     -metadata:s:v language=und -metadata:s:a language=und 
                     -map_chapters -1 
                     -y -f mp4)
   
   # Détection du format vidéo avec gestion d'erreur
   local video_codec
   video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
   
   # Détection de la profondeur de bits
   local bit_depth
   bit_depth=$(ffprobe -v error -select_streams v:0 -show_entries stream=bits_per_raw_sample -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
   
   # Si bit_depth est vide, essayons avec pix_fmt
   if [ -z "$bit_depth" ] || [ "$bit_depth" = "N/A" ]; then
       local pix_fmt
       pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
       
       # Détecter si c'est un format 10 bits basé sur le pix_fmt
       if [[ "$pix_fmt" == *"10"* ]] || [[ "$pix_fmt" == *"p10"* ]] || [[ "$pix_fmt" == *"yuv420p10"* ]]; then
           bit_depth="10"
       else
           bit_depth="8"  # Par défaut on suppose 8 bits
       fi
   fi
   
   # Création d'un fichier temporaire pour les erreurs
   local temp_error_file="/tmp/ffmpeg_error_$$.log"
   
   # Conversion avec différentes options selon le codec source et la profondeur de bits
   if [[ "$bit_depth" == "10" ]] || [[ "$video_codec" == "vp9" ]] || [[ "$video_codec" == "vp8" ]] || [[ "$video_codec" == "hevc" && "$bit_depth" == "10" ]]; then
       log "⚠️ Vidéo 10 bits détectée pour segment $segment_index - libx264 avec conversion 8 bits"
       # Modification des options pour utiliser libx264 avec conversion en 8 bits
       common_opts=(-ss "$start_time" -t "$duration"
                   -map 0:v:0 -map 0:a:0? -sn
                   -vf format=yuv420p  # Force la conversion en 8 bits
                   -c:v libx264 -preset medium -profile:v high -level 4.1 
                   -b:v 2M -maxrate 2.5M -bufsize 5M 
                   -c:a aac -b:a 192k -ac 2 
                   -movflags +faststart 
                   -metadata:s:v language=und -metadata:s:a language=und 
                   -map_chapters -1 
                   -y -f mp4)
                   
       ffmpeg -v warning -i "$input_file" "${common_opts[@]}" "$segment_output" 2> "$temp_error_file"
   else
       # Accélération matérielle pour les vidéos 8 bits avec codecs compatibles
       log "🚀 Segment $segment_index - Utilisation accélération GPU CUDA"
       ffmpeg -v warning -hwaccel cuda -hwaccel_output_format cuda -hwaccel_device 0 -c:v h264_cuvid -surfaces 8 -i "$input_file" "${common_opts[@]}" "$segment_output" 2> "$temp_error_file"
       
       # Vérification d'erreur "No decoder surfaces"
       if [ ! -s "$segment_output" ] || grep -q "No decoder surfaces" "$temp_error_file"; then
           log "⚠️ Segment $segment_index - Problème de ressources GPU, utilisation décodage CPU"
           ffmpeg -v warning -i "$input_file" "${common_opts[@]}" "$segment_output" 2>> "$temp_error_file"
       fi
   fi
   
   # Récupération des erreurs
   if [ -f "$temp_error_file" ]; then
       local error_output=$(cat "$temp_error_file")
       if [ -n "$error_output" ]; then
           log_error "Erreurs ffmpeg pour segment $segment_index:"
           log_error "$error_output"
       fi
       rm -f "$temp_error_file"
   fi
   
   # Vérification que le fichier a bien été créé et qu'il n'est pas vide
   if [ -f "$segment_output" ] && [ -s "$segment_output" ]; then
       local filesize=$(du -h "$segment_output" | cut -f1)
       log "✅ Segment $segment_index transcodé avec succès (${filesize})"
       return 0
   else
       log_error "❌ Échec segment $segment_index"
       return 1
   fi
}
# Fonction pour fusionner les segments
merge_segments() {
    local output_file="$1"
    local total_segments="$2"
    
    log "Fusion de $total_segments segments en fichier final: $(basename "$output_file")"
    
    # Création d'un fichier de liste pour la fusion
    local segment_list="/tmp/segments_$$.txt"
    
    # Vérification des segments et création du fichier de liste
    echo "" > "$segment_list"
    local missing_segments=0
    
    for ((i=0; i<total_segments; i++)); do
        local segment="${output_file%.*}_segment_${i}.mp4"
        if [ -f "$segment" ] && [ -s "$segment" ]; then
            echo "file '$segment'" >> "$segment_list"
        else
            log_error "Segment manquant ou vide pour la fusion: $(basename "$segment")"
            missing_segments=$((missing_segments + 1))
        fi
    done
    
    # Si des segments sont manquants, on échoue
    if [ $missing_segments -gt 0 ]; then
        log_error "$missing_segments segments manquants sur $total_segments, fusion impossible"
        return 1
    fi
    
    # Vérification et log du contenu du fichier de liste
    log "Contenu du fichier de liste des segments:"
    local list_content=$(cat "$segment_list")
    if [ -z "$list_content" ]; then
        log_error "Fichier de liste des segments vide!"
        return 1
    fi
    
    while IFS= read -r line; do
        log "  $line"
    done < "$segment_list"
    
    # Fusion des segments avec ffmpeg
    ffmpeg -f concat -safe 0 -i "$segment_list" -c copy "$output_file" 2>> "$ERROR_LOG_FILE"
    
    # Vérification que le fichier final a bien été créé
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        local filesize=$(du -h "$output_file" | cut -f1)
        log "✅ Fusion réussie: $(basename "$output_file") (${filesize})"
        
        # Nettoyage des segments
        for ((i=0; i<total_segments; i++)); do
            rm -f "${output_file%.*}_segment_${i}.mp4"
        done
        
        # Suppression du fichier d'état
        if [ -f "$RESUME_STATE_FILE" ]; then
            rm -f "$RESUME_STATE_FILE"
        fi
        
        return 0
    else
        log_error "❌ Échec de fusion pour: $(basename "$output_file")"
        return 1
    fi
}

# Fonction pour convertir les fichiers par segments
convert_file_segments() {
    local input_file="$1"
    local output_file="$2"
    local resume_segment="${3:-0}"  # Défaut à 0 si non spécifié
    local resume_total="${4:-0}"    # Défaut à 0 si non spécifié
    local segment_duration=60       # Durée de chaque segment en secondes
    
    log "Conversion par segments du fichier: $(basename "$input_file")"
    
    # Vérification des droits d'accès
    if [ ! -r "$input_file" ]; then
        log_error "Impossible de lire le fichier source: $input_file"
        return 1
    fi
    
    # Vérification de l'espace disponible
    check_disk_space "$OUTPUT_DIR"
    
    # Obtention de la durée totale de la vidéo
    local duration
    duration=$(get_video_duration "$input_file")
    
    if [ "$duration" -eq 0 ]; then
        log_error "Impossible de déterminer la durée de la vidéo: $input_file"
        return 1
    fi
    
    # Calcul du nombre total de segments
    # Calcul du nombre total de segments, ou utilisation du paramètre
    local total_segments
    if [ "$resume_total" -gt 0 ]; then
        total_segments=$resume_total
    else
        total_segments=$((duration / segment_duration + 1))
    fi
    
    # Définir le segment de départ
    local start_segment=$resume_segment    
    log "Durée totale: $duration secondes - $total_segments segments à créer"
    
    # Gestion de la reprise - check si le fichier d'état existe et concerne ce fichier
    if load_state; then
        local saved_input=$(grep -o '"input_file":"[^"]*"' "$RESUME_STATE_FILE" | cut -d'"' -f4)
        local saved_output=$(grep -o '"output_file":"[^"]*"' "$RESUME_STATE_FILE" | cut -d'"' -f4)
        local saved_segment=$(grep -o '"current_segment":[0-9]*' "$RESUME_STATE_FILE" | cut -d':' -f2)
        local saved_total=$(grep -o '"total_segments":[0-9]*' "$RESUME_STATE_FILE" | cut -d':' -f2)
        
        if [ "$saved_input" == "$input_file" ]; then
            log "Reprise de conversion pour $(basename "$input_file") à partir du segment $((saved_segment + 1))/$saved_total"
            start_segment=$((saved_segment + 1))
            total_segments=$saved_total
        else
            log "Démarrage d'une nouvelle conversion (l'état sauvegardé concerne un autre fichier)"
        fi
    fi
    
    log "Traitement de $total_segments segments (reprise à $start_segment)"
    
    # Transcodage de chaque segment
    local success=true
    for ((i=start_segment; i<total_segments; i++)); do
        # Sauvegarde de l'état actuel
        save_state "$input_file" "$i" "$total_segments" "$output_file"
        
        # Calcul du point de départ du segment
        local segment_start=$((i * segment_duration))
        
        # Transcodage du segment
        if ! transcode_segment "$input_file" "$output_file" "$segment_start" "$segment_duration" "$i" "$total_segments"; then
            log_error "Échec lors du transcodage du segment $i/$total_segments"
            success=false
            break
        fi
    done
    
    # Si tous les segments ont été transcodés avec succès, on les fusionne
    if $success; then
        if ! merge_segments "$output_file" "$total_segments"; then
            log_error "Échec lors de la fusion des segments"
            return 1
        fi
        return 0
    else
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
        # On cherche les fichiers avec cette extension
        for file in "$input_dir"/*.$ext; do
            # Vérifie si le fichier existe et n'est pas un wildcard non résolu
            if [ -f "$file" ] 2>/dev/null; then
                # On sauvegarde le chemin complet comme clé du tableau associatif
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
    
    # Vérification si une reprise est en cours
    if [ -f "$RESUME_STATE_FILE" ]; then
        local saved_input=$(grep -o '"input_file":"[^"]*"' "$RESUME_STATE_FILE" | cut -d'"' -f4)
        local saved_output=$(grep -o '"output_file":"[^"]*"' "$RESUME_STATE_FILE" | cut -d'"' -f4)
        local saved_segment=$(grep -o '"current_segment":[0-9]*' "$RESUME_STATE_FILE" | cut -d':' -f2)
        local saved_total=$(grep -o '"total_segments":[0-9]*' "$RESUME_STATE_FILE" | cut -d':' -f2)
        
        # Extraire le nom de fichier sans chemin
        local base_saved_input=$(basename "$saved_input")
        
        # Recherche par nom de fichier pour reprise
        local found_file_to_resume=false
        for file in "${!files_to_process[@]}"; do
            if [ "$(basename "$file")" = "$base_saved_input" ]; then
                found_file_to_resume=true
                log "📎 Reprise de conversion à partir du segment $((saved_segment + 1))/$saved_total"
                
                # Conversion avec reprise
                if convert_file_segments "$file" "$saved_output" $((saved_segment + 1)) "$saved_total"; then
                    converted_files=$((converted_files + 1))
                else
                    failed_files=$((failed_files + 1))
                fi
                
                # On retire ce fichier de la liste
                unset files_to_process["$file"]
                break
            fi
        done
        
        # Si aucun fichier correspondant trouvé
        if [ "$found_file_to_resume" = false ]; then
            log "⚠️ Fichier de reprise non trouvé dans le dossier d'entrée"
        fi
    fi
    
    # Traitement des fichiers restants
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
            # On lance la conversion par segments
            if convert_file_segments "$file" "$output_file"; then
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
    
    # Création du dossier pour les segments
    mkdir -p "$SEGMENTS_DIR"
    
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
    
    log "🚀 Démarrage du processus de conversion par segments pour IPTV (avec reprise)"
    if ! process_directory "$input_dir"; then
        log_error "Des problèmes sont survenus pendant la conversion"
        exit 1
    fi
    log "✨ Toutes les conversions sont terminées!"
}

# Exécution du script
main "$@"