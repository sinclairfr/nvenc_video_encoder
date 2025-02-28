#!/bin/bash

# Définition des dossiers et fichiers
INPUT_DIR="/input"
OUTPUT_DIR="/output"
RESUME_STATE_FILE="/resume_state/resume_state.json"
LOG_FILE="/output/conversion.log"
ERROR_LOG_FILE="/output/error.log"
mkdir -p "$OUTPUT_DIR"

# Initialisation des fichiers de log
echo "=== Démarrage de la conversion $(date) ===" > "$LOG_FILE"
echo "=== VERSION: 1.4.0 ===" >> "$LOG_FILE"
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

# Fonction pour sauvegarder l'état de la conversion avec ajout au fichier existant
save_state() {
    local file="$1"
    local segment_index="$2"
    local total_segments="$3"
    local output_file="$4"
    local file_id=$(basename "$file" | md5sum | cut -d' ' -f1)
    
    # Format simple d'état en JSON minimaliste
    local state_entry="{\"file_id\":\"$file_id\",\"input_file\":\"$file\",\"output_file\":\"$output_file\",\"current_segment\":$segment_index,\"total_segments\":$total_segments,\"timestamp\":\"$(date '+%Y-%m-%d %H:%M:%S')\"}"
    
    # Si le fichier d'état n'existe pas, on le crée
    if [ ! -f "$RESUME_STATE_FILE" ]; then
        echo "{\"conversions\":[" > "$RESUME_STATE_FILE"
        echo "$state_entry" >> "$RESUME_STATE_FILE"
        echo "]}" >> "$RESUME_STATE_FILE"
    else
        # On fait une sauvegarde du fichier
        cp "$RESUME_STATE_FILE" "${RESUME_STATE_FILE}.bak"
        
        # On vérifie si le fichier existe déjà dans l'état
        if grep -q "\"file_id\":\"$file_id\"" "$RESUME_STATE_FILE"; then
            # On remplace l'entrée existante avec sed
            sed -i "s|{\"file_id\":\"$file_id\".*}|$state_entry|g" "$RESUME_STATE_FILE"
        else
            # On ajoute la nouvelle entrée (on remplace la dernière accolade par l'entrée + accolade)
            sed -i "s|]}|,$state_entry]}|" "$RESUME_STATE_FILE"
        fi
    fi
    
    log "État sauvegardé: fichier $file, segment $segment_index/$total_segments"
}

# Fonction pour charger l'état précédent d'un fichier spécifique
load_state() {
    local file="$1"
    local file_id=$(basename "$file" | md5sum | cut -d' ' -f1)
    
    if [ -f "$RESUME_STATE_FILE" ]; then
        # On extrait la ligne correspondant au fichier
        local state_line=$(grep -o "{\"file_id\":\"$file_id\"[^}]*}" "$RESUME_STATE_FILE")
        
        if [ -n "$state_line" ]; then
            # Extraction des valeurs avec grep et sed
            local saved_segment=$(echo "$state_line" | grep -o '"current_segment":[0-9]*' | sed 's/"current_segment"://')
            local saved_total=$(echo "$state_line" | grep -o '"total_segments":[0-9]*' | sed 's/"total_segments"://')
            
            if [ -n "$saved_segment" ] && [ -n "$saved_total" ]; then
                log "Reprise de conversion pour $(basename "$file") à partir du segment $((saved_segment + 1))/$saved_total"
                echo "$saved_segment $saved_total"
                return 0
            fi
        fi
    fi
    
    return 1
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
transcode_segment() {
   local input_file="$1"
   local output_file="$2"
   local start_time="$3"
   local duration="$4"
   local segment_index="$5"
   local total_segments="$6"
   
   # Création du répertoire segments dans le dossier de sortie
   local segments_dir="${OUTPUT_DIR}/segments"
   mkdir -p "$segments_dir"
   
   # Nom du fichier sans chemin pour éviter les problèmes de structure
   local base_filename=$(basename "${output_file%.*}")
   local segment_output="${segments_dir}/${base_filename}_segment_${segment_index}.mp4"
   
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
    # À la fin de la fonction, après la vérification de la création du fichier
    if [ -f "$segment_output" ] && [ -s "$segment_output" ]; then
        local filesize=$(du -h "$segment_output" | cut -f1)
        log "✅ Segment $segment_index transcodé avec succès (${filesize})"
        echo "$segment_output"
        return 0
    else
        log_error "❌ Échec segment $segment_index"
        return 1
    fi
}

# Fonction pour fusionner les segments
# Fonction pour fusionner les segments
merge_segments() {
    local output_file="$1"
    local segments_dir="${OUTPUT_DIR}/segments"
    local base_filename=$(basename "${output_file%.*}")
    local segment_list="/tmp/segments_$$.txt"
    
    log "Fusion des segments en fichier final: $(basename "$output_file")"
    
    # Trouver tous les segments pour ce fichier spécifique
    find "$segments_dir" -name "${base_filename}_segment_*.mp4" -type f -size +0 | sort -V > /tmp/found_segments_$$.txt
    
    local total_found=$(wc -l < /tmp/found_segments_$$.txt)
    log "Trouvé $total_found segments dans $segments_dir pour $base_filename"
    
    if [ $total_found -eq 0 ]; then
        log_error "Aucun segment trouvé. Vérifiez le nom du fichier et les chemins."
        return 1
    fi
    
    # Créer le fichier de liste pour ffmpeg
    while IFS= read -r segment; do
        echo "file '$segment'" >> "$segment_list"
    done < /tmp/found_segments_$$.txt
    
    # Vérifier taille attendue vs taille réelle
    local source_file=$(find "$INPUT_DIR" -name "${base_filename}.*" -type f | head -1)
    local source_size=0
    if [ -f "$source_file" ]; then
        source_size=$(du -k "$source_file" | cut -f1)
        log "Taille source: ${source_size}K"
    fi
    
    # Amélioration de la fusion avec options supplémentaires
    ffmpeg -f concat -safe 0 -i "$segment_list" -c copy -map 0 -map_metadata 0 "$output_file" 2>> "$ERROR_LOG_FILE"
    
    # Nettoyage
    rm -f "$segment_list" /tmp/found_segments_$$.txt
    
    # Vérification
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        local target_size=$(du -k "$output_file" | cut -f1)
        local filesize=$(du -h "$output_file" | cut -f1)
        
        log "✅ Fusion réussie: $(basename "$output_file") (${filesize})"
        
        if [ $source_size -gt 0 ]; then
            local ratio=$((target_size * 100 / source_size))
            log "Taux de compression: ${ratio}% (source: ${source_size}K, final: ${target_size}K)"
            
            if [ $ratio -lt 20 ]; then
                log_error "⚠️ Compression excessive détectée - vérifier si des segments manquent!"
                # Ajouter un diagnostic plus détaillé
                log_error "Vérification des segments:"
                for segment in $(cat /tmp/found_segments_$$.txt); do
                    log_error "Segment: $segment, Taille: $(du -h "$segment")"
                done
            fi
        fi
        
        return 0
    else
        log_error "❌ Échec de fusion pour: $(basename "$output_file")"
        return 1
    fi
}

# Fonction pour convertir les fichiers par segments
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
    # Gestion de la reprise - check si le fichier d'état existe et concerne ce fichier
    local state_result=$(load_state "$input_file")
    local load_status=$?

    if [ $load_status -eq 0 ] && [ -n "$state_result" ]; then
        # Filtrer les lignes de log qui commencent par [date]
        state_result=$(echo "$state_result" | grep -v "^\[.*\]")
        
        # Le format est maintenant "segment total"
        read saved_segment saved_total <<< "$state_result"
        
        # Vérifier que les variables ont bien été extraites et sont numériques
        if [[ "$saved_segment" =~ ^[0-9]+$ ]] && [[ "$saved_total" =~ ^[0-9]+$ ]]; then
            log "Reprise de conversion pour $(basename "$input_file") à partir du segment $((saved_segment + 1))/$saved_total"
            start_segment=$((saved_segment + 1))
            total_segments=$saved_total
        else
            log "État de reprise invalide, démarrage d'une nouvelle conversion"
        fi
    else
        log "Démarrage d'une nouvelle conversion"
    fi
    
    log "Traitement de $total_segments segments (reprise à $start_segment)"
    
    # Liste pour stocker les chemins des segments
    local segments_paths=""
    
    # Transcodage de chaque segment
    local success=true
    for ((i=start_segment; i<total_segments; i++)); do
        # Sauvegarde de l'état actuel
        save_state "$input_file" "$i" "$total_segments" "$output_file"
        
        # Calcul du point de départ du segment
        local segment_start=$((i * segment_duration))
        
        # Transcodage du segment
        local segment_path
        segment_path=$(transcode_segment "$input_file" "$output_file" "$segment_start" "$segment_duration" "$i" "$total_segments")
        
        if [ $? -ne 0 ]; then
            log_error "Échec lors du transcodage du segment $i/$total_segments"
            success=false
            break
        fi
        
        # Ajout du chemin du segment à la liste
        segments_paths="${segments_paths}${segment_path}
"
    done
    
    # Si tous les segments ont été transcodés avec succès, on les fusionne
    if $success; then
        if ! merge_segments "$output_file" "$segments_paths"; then
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
    
    # Création du dossier pour les segments dans input
    mkdir -p "${input_dir}/segments"
    
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