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
    
    # Échapper les caractères spéciaux pour JSON
    local sanitized_input=$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local sanitized_output=$(printf '%s' "$output_file" | sed 's/\\/\\\\/g; s/"/\\"/g')
    
    # Format d'état JSON avec noms de fichiers échappés
    local state_entry="{\"file_id\":\"$file_id\",\"input_file\":\"$sanitized_input\",\"output_file\":\"$sanitized_output\",\"current_segment\":$segment_index,\"total_segments\":$total_segments,\"timestamp\":\"$(date '+%Y-%m-%d %H:%M:%S')\"}"
    
    # Crée le dossier de résumé s'il n'existe pas
    mkdir -p "$(dirname "$RESUME_STATE_FILE")"
    
    # Si le fichier d'état n'existe pas, on le crée
    if [ ! -f "$RESUME_STATE_FILE" ]; then
        echo "{\"conversions\":[" > "$RESUME_STATE_FILE"
        echo "$state_entry" >> "$RESUME_STATE_FILE"
        echo "]}" >> "$RESUME_STATE_FILE"
    else
        # On fait une sauvegarde du fichier
        cp "$RESUME_STATE_FILE" "${RESUME_STATE_FILE}.bak"
        
        # Fichier temporaire
        local temp_file="/tmp/resume_state_$$.json"
        
        # On utilise un fichier temporaire pour reconstruire le JSON
        # Cela évite les problèmes avec les caractères spéciaux et sed
        {
            # Début du fichier JSON
            echo "{\"conversions\":["
            
            # On obtient les entrées existantes
            grep -o "{\"file_id\":[^}]*}" "$RESUME_STATE_FILE" | grep -v "\"file_id\":\"$file_id\"" | tr '\n' ',' | sed 's/,$//'
            
            # On ajoute une virgule s'il y a des entrées existantes
            if grep -q "\"file_id\":" "$RESUME_STATE_FILE"; then
                echo ","
            fi
            
            # On ajoute la nouvelle entrée
            echo "$state_entry"
            
            # Fin du fichier JSON
            echo "]}"
        } > "$temp_file"
        
        # On remplace le fichier original
        mv "$temp_file" "$RESUME_STATE_FILE"
    fi
    
    log "État sauvegardé: fichier $file, segment $segment_index/$total_segments"
}

# Fonction auxiliaire pour la mise à jour manuelle de l'état
manual_state_update() {
    local file_id="$1"
    local state_entry="$2"
    
    # On vérifie si le fichier existe déjà dans l'état
    if grep -q "\"file_id\":\"$file_id\"" "$RESUME_STATE_FILE"; then
        # On remplace l'entrée existante en utilisant un fichier temporaire
        local temp_file="/tmp/resume_state_$$.json"
        awk -v id="\"file_id\":\"$file_id\"" -v entry="$state_entry" '
        {
            if (index($0, id) > 0) {
                print entry;
            } else {
                print $0;
            }
        }' "$RESUME_STATE_FILE" > "$temp_file"
        mv "$temp_file" "$RESUME_STATE_FILE"
    else
        # On ajoute la nouvelle entrée (on remplace la dernière accolade par l'entrée + accolade)
        sed -i "s|]}|,$state_entry]}|" "$RESUME_STATE_FILE"
    fi
}

# Fonction pour charger l'état précédent d'un fichier spécifique
load_state() {
    local input_file="$1"
    local file_id=$(basename "$input_file" | md5sum | cut -d' ' -f1)
    
    if [ -f "$RESUME_STATE_FILE" ]; then
        # On utilise grep avec l'identifiant md5 qui est plus fiable que le nom de fichier
        local state_line=$(grep -o "{\"file_id\":\"$file_id\"[^}]*}" "$RESUME_STATE_FILE")
        
        if [ -n "$state_line" ]; then
            # Extraction des valeurs avec sed qui gère mieux les caractères spéciaux
            local saved_segment=$(echo "$state_line" | sed -n 's/.*"current_segment":\([0-9]*\).*/\1/p')
            local saved_total=$(echo "$state_line" | sed -n 's/.*"total_segments":\([0-9]*\).*/\1/p')
            
            if [ -n "$saved_segment" ] && [ -n "$saved_total" ]; then
                log "Reprise de conversion pour $(basename "$input_file") à partir du segment $((saved_segment + 1))/$saved_total"
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
# Fonction pour transcoder un segment (modifiée)
# Fonction pour transcoder un segment avec réessais
transcode_segment() {
   local input_file="$1"
   local output_file="$2"
   local start_time="$3"
   local duration="$4"
   local segment_index="$5"
   local total_segments="$6"
   local max_retries=3  # Nombre maximal de tentatives
   local retry_count=0
   
   # Création du répertoire segments dans le dossier de sortie
   local segments_dir="${OUTPUT_DIR}/segments"
   mkdir -p "$segments_dir"
   
   # Nom du fichier sans chemin pour éviter les problèmes de structure
   # Dans la fonction transcode_segment
   local base_filename=$(basename "${output_file%.*}")
   # Nettoyer les duplications potentielles de "segment" dans le nom
   base_filename=$(echo "$base_filename" | sed 's/_segment_[0-9]*$//')
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
   log "Codec vidéo détecté: $video_codec"
   
   # Détection de la profondeur de bits
   local bit_depth
   bit_depth=$(ffprobe -v error -select_streams v:0 -show_entries stream=bits_per_raw_sample -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
   
   # Si bit_depth est vide, essayons avec pix_fmt
   if [ -z "$bit_depth" ] || [ "$bit_depth" = "N/A" ]; then
       local pix_fmt
       pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>> "$ERROR_LOG_FILE")
       log "Format de pixel détecté: $pix_fmt"
       
       # Détecter si c'est un format 10 bits basé sur le pix_fmt
       if [[ "$pix_fmt" == *"10"* ]] || [[ "$pix_fmt" == *"p10"* ]] || [[ "$pix_fmt" == *"yuv420p10"* ]]; then
           bit_depth="10"
       else
           bit_depth="8"  # Par défaut on suppose 8 bits
       fi
   fi
   log "Profondeur de bits détectée: $bit_depth"
   
   # Boucle de tentatives
   while [ $retry_count -lt $max_retries ]; do
       # Création d'un fichier temporaire pour les erreurs
       local temp_error_file="/tmp/ffmpeg_error_$$.log"
       
       # Pour VP9, essayons d'abord avec libvpx-vp9 pour le décodage
       if [[ "$video_codec" == "vp9" ]]; then
           log "🔄 Tentative #$((retry_count+1)) - VP9 détecté, utilisation de libvpx-vp9"
           
           # Ajustement pour VP9
           ffmpeg -v warning -i "$input_file" \
               -ss "$start_time" -t "$duration" \
               -map 0:v:0 -map 0:a:0? -sn \
               -vf "format=yuv420p" \
               -c:v libx264 -preset medium -profile:v main -level 4.1 \
               -b:v 2M -maxrate 2.5M -bufsize 5M \
               -c:a aac -b:a 192k -ac 2 \
               -movflags +faststart \
               -metadata:s:v language=und -metadata:s:a language=und \
               -map_chapters -1 \
               -y -f mp4 "$segment_output" 2> "$temp_error_file"
       elif [[ "$bit_depth" == "10" ]] || [[ "$video_codec" == "hevc" && "$bit_depth" == "10" ]]; then
           log "🔄 Tentative #$((retry_count+1)) - Vidéo 10 bits détectée, utilisation libx264 avec conversion 8 bits"
           # Modification des options pour utiliser libx264 avec conversion en 8 bits
           ffmpeg -v warning -i "$input_file" \
               -ss "$start_time" -t "$duration" \
               -map 0:v:0 -map 0:a:0? -sn \
               -vf "format=yuv420p" \
               -c:v libx264 -preset medium -profile:v high -level 4.1 \
               -b:v 2M -maxrate 2.5M -bufsize 5M \
               -c:a aac -b:a 192k -ac 2 \
               -movflags +faststart \
               -metadata:s:v language=und -metadata:s:a language=und \
               -map_chapters -1 \
               -y -f mp4 "$segment_output" 2> "$temp_error_file"
       else
           # En fonction du nombre de tentatives, on essaie différentes approches
           if [ $retry_count -eq 0 ]; then
               log "🔄 Tentative #$((retry_count+1)) - Utilisation accélération GPU CUDA"
               ffmpeg -v warning -hwaccel cuda -hwaccel_output_format cuda -hwaccel_device 0 -c:v h264_cuvid -surfaces 8 -i "$input_file" "${common_opts[@]}" "$segment_output" 2> "$temp_error_file"
           elif [ $retry_count -eq 1 ]; then
               log "🔄 Tentative #$((retry_count+1)) - Utilisation décodage CPU"
               ffmpeg -v warning -i "$input_file" "${common_opts[@]}" "$segment_output" 2> "$temp_error_file"
           else
               log "🔄 Tentative #$((retry_count+1)) - Utilisation libx264 (CPU) en dernier recours"
               ffmpeg -v warning -i "$input_file" \
                   -ss "$start_time" -t "$duration" \
                   -map 0:v:0 -map 0:a:0? -sn \
                   -c:v libx264 -preset medium -profile:v main \
                   -b:v 2M -maxrate 2.5M -bufsize 5M \
                   -c:a aac -b:a 192k -ac 2 \
                   -movflags +faststart \
                   -metadata:s:v language=und -metadata:s:a language=und \
                   -map_chapters -1 \
                   -y -f mp4 "$segment_output" 2> "$temp_error_file"
           fi
       fi
       
       # Récupération des erreurs
       if [ -f "$temp_error_file" ]; then
           local error_output=$(cat "$temp_error_file")
           if [ -n "$error_output" ]; then
               log_error "Erreurs ffmpeg pour segment $segment_index (tentative $((retry_count+1))):"
               log_error "$error_output"
           fi
           rm -f "$temp_error_file"
       fi
       
       # Vérification que le fichier a bien été créé et qu'il n'est pas vide
       if [ -f "$segment_output" ] && [ -s "$segment_output" ]; then
           local filesize=$(du -h "$segment_output" | cut -f1)
           log "✅ Segment $segment_index transcodé avec succès (${filesize}) après $((retry_count+1)) tentative(s)"
           echo "$segment_output"
           return 0
       else
           log_error "❌ Échec segment $segment_index (tentative $((retry_count+1)))"
           retry_count=$((retry_count + 1))
           
           # Petite pause avant de réessayer
           sleep 2
       fi
   done
   
   log_error "❌ Échec définitif du segment $segment_index après $max_retries tentatives"
   return 1
}
# Fonction pour nettoyer les noms de fichiers (à ajouter)
clean_filename() {
    local filename="$1"
    # Supprimer les duplications de "_segment_X"
    echo "$filename" | sed 's/_segment_[0-9]*//g'
}
# Fonction pour assainir les noms de fichiers problématiques
sanitize_filename() {
    local input_dir="$1"
    local log_prefix="[NETTOYAGE]"
    
    log "$log_prefix Vérification des noms de fichiers problématiques..."
    
    # On parcourt tous les formats vidéo courants
    for ext in mp4 mkv avi mov webm wmv flv ts m4v; do
        # On cherche les fichiers avec des caractères spéciaux ou espaces
        find "$input_dir" -type f -name "*.$ext" | while read -r file; do
            local filename=$(basename "$file")
            local dirname=$(dirname "$file")
            
            # Si le nom contient des caractères problématiques
            if echo "$filename" | grep -q '[：；＜＞，？　 ]'; then
                log "$log_prefix Fichier avec caractères spéciaux détecté: $filename"
                
                # Crée un nouveau nom sans caractères spéciaux, garde l'extension d'origine
                local base="${filename%.*}"
                local extension="${filename##*.}"
                local new_name=$(echo "$base" | sed 's/[：；＜＞，？　 ]/_/g')."$extension"
                
                log "$log_prefix Renommage de '$filename' en '$new_name'"
                
                # Renomme le fichier
                mv "$file" "$dirname/$new_name"
                
                if [ $? -eq 0 ]; then
                    log "$log_prefix ✅ Fichier renommé avec succès"
                else
                    log_error "$log_prefix ❌ Échec du renommage"
                fi
            fi
        done
    done
    
    log "$log_prefix Nettoyage des noms de fichiers terminé"
}
# Fonction pour fusionner les segments (modifiée pour format 3 chiffres)
merge_segments() {
    local output_file="$1"
    local segments_dir="${OUTPUT_DIR}/segments"
    local base_filename=$(basename "${output_file%.*}")
    # On supprime d'éventuels _segment_ déjà présents dans le nom
    base_filename=$(echo "$base_filename" | sed 's/_segment_[0-9]*$//')
    local segment_list="/tmp/segments_$$.txt"
    
    # IMPORTANT: Initialisation du fichier de liste (cette ligne manque)
    > "$segment_list"
    
    log "Fusion des segments en fichier final: $(basename "$output_file")"
        
    # Trouver tous les segments pour ce fichier spécifique
    find "$segments_dir" -name "${base_filename}_segment_*.mp4" -type f -size +0 | sort -V > /tmp/found_segments_$$.txt
    
    local total_found=$(wc -l < /tmp/found_segments_$$.txt)
    log "Trouvé $total_found segments dans $segments_dir pour $base_filename"
    
    if [ $total_found -eq 0 ]; then
        log_error "Aucun segment trouvé. Vérifiez le nom du fichier et les chemins."
        return 1
    fi
    
    # Vérifier la continuité des segments
    local missing_segments=""
    local prev_index=-1
    for segment in $(cat /tmp/found_segments_$$.txt); do
        # Utiliser une méthode plus fiable pour extraire le numéro
        local current_index=$(basename "$segment" | grep -o "_segment_[0-9]*" | sed 's/_segment_//')
        
        # Conversion en entier pour éviter les problèmes de base
        current_index=$((10#$current_index))
        
        if [ $prev_index -ne -1 ]; then
            local expected_index=$((prev_index + 1))
            if [ "$current_index" -ne "$expected_index" ]; then
                missing_segments="$missing_segments $expected_index"
                log_error "Segment manquant: $expected_index (entre $prev_index et $current_index)"
            fi
        fi
        prev_index=$current_index
    done
    
    if [ -n "$missing_segments" ]; then
        log_error "Attention: Segments manquants détectés: $missing_segments"
        log_error "Vérifiez les erreurs pour ces segments spécifiques"
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
    # Amélioration de la fusion avec options supplémentaires
    log "Démarrage de la fusion avec $(wc -l < "$segment_list") segments listés"
    # Afficher les 5 premiers segments pour debug
    head -n 5 "$segment_list" | while read line; do
        log "  Segment: $line"
    done
    ffmpeg -f concat -safe 0 -i "$segment_list" -c copy -map 0 -map_metadata 0 "$output_file" 2>> "$ERROR_LOG_FILE"
    
    # Nettoyage
    rm -f "$segment_list" /tmp/found_segments_$$.txt
    
    # Vérification
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        local target_size=$(du -k "$output_file" | cut -f1)
        local filesize=$(du -h "$output_file" | cut -f1)
        
        log "✅ Fusion réussie: $(basename "$output_file") (${filesize})"
        local segments_base="${segments_dir}/${base_filename}_segment_"
        log "💡 Suggestion: rm -rf \"${segments_base}\"* pour supprimer les segments temporaires"
        
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
# Vérifier la séquence de segments pour détecter les trous
check_segments_sequence() {
    local base_filename="$1"
    local segments_dir="${OUTPUT_DIR}/segments"
    local expected_total="$2"
    
    log "Vérification de la séquence des segments..."
    
    # Liste tous les segments existants avec leur numéro extrait
    find "$segments_dir" -name "${base_filename}_segment_*.mp4" -type f -size +0 | while read -r seg_file; do
        # Extrait le numéro de segment (format 3 chiffres)
        seg_num=$(echo "$seg_file" | grep -o '_segment_[0-9][0-9][0-9]' | sed 's/_segment_//')
        
        # Convertit en nombre (supprime les zéros en tête)
        seg_num=$((10#$seg_num))
        
        echo "$seg_num"
    done | sort -n > /tmp/existing_segments_$$.txt
    
    # Vérifier les segments manquants
    local prev=0
    local missing=0
    
    while read -r num; do
        # Si l'écart est supérieur à 1, il y a des segments manquants
        if [ $((num - prev)) -gt 1 ]; then
            for ((i=prev+1; i<num; i++)); do
                formatted_i=$(printf "%03d" $i)
                log_error "❌ Segment manquant: ${base_filename}_segment_${formatted_i}.mp4"
                missing=$((missing + 1))
            done
        fi
        prev=$num
    done < /tmp/existing_segments_$$.txt
    
    # Vérifier si tous les segments attendus sont présents
    local found=$(wc -l < /tmp/existing_segments_$$.txt)
    
    if [ "$found" -lt "$expected_total" ]; then
        log_error "❌ Segments manquants: $missing détectés, $found trouvés sur $expected_total attendus"
        return 1
    else
        log "✅ Séquence de segments complète: $found sur $expected_total"
        return 0
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
# Fonction pour vérifier la taille des segments et relancer si nécessaire
check_segment_size() {
    local segment_file="$1"
    local min_size=5000000  # Taille minimale (5Mo)
    local input_file="$2"
    local start_time="$3"
    local duration="$4"
    local segment_index="$5"
    local total_segments="$6"
    local retry_count=2
    
    # Vérifier si le fichier existe
    if [ ! -f "$segment_file" ]; then
        log_error "Segment introuvable: $segment_file"
        return 1
    fi
    
    # Vérifier la taille du fichier
    local file_size=$(stat -c %s "$segment_file")
    
    if [ "$file_size" -lt "$min_size" ]; then
        log_error "Segment $segment_index trop petit (${file_size} octets < ${min_size} octets), tentative de reconversion..."
        
        # Tentatives de reconversion
        for ((retry=1; retry<=retry_count; retry++)); do
            log "Tentative $retry/$retry_count pour le segment $segment_index"
            
            # Supprimer l'ancien segment
            rm -f "$segment_file"
            
            # Reconvertir le segment avec un délai aléatoire
            sleep $((RANDOM % 3 + 1))
            local new_segment=$(transcode_segment "$input_file" "${segment_file%_*}.mp4" "$start_time" "$duration" "$segment_index" "$total_segments")
            
            if [ $? -eq 0 ]; then
                local new_size=$(stat -c %s "$new_segment")
                if [ "$new_size" -ge "$min_size" ]; then
                    log "✅ Reconversion réussie pour segment $segment_index (nouvelle taille: $new_size octets)"
                    return 0
                fi
            fi
        done
        
        log_error "❌ Échec après $retry_count tentatives pour segment $segment_index"
        return 1
    fi
    
    return 0
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
# Fonction pour vérifier la taille des segments et relancer si nécessaire
check_segment_size() {
    local segment_file="$1"
    local min_size=5000000  # Taille minimale (5Mo)
    local input_file="$2"
    local start_time="$3"
    local duration="$4"
    local segment_index="$5"
    local total_segments="$6"
    local retry_count=2
    
    # Vérifier si le fichier existe
    if [ ! -f "$segment_file" ]; then
        log_error "Segment introuvable: $segment_file"
        return 1
    fi
    
    # Vérifier la taille du fichier
    local file_size=$(stat -c %s "$segment_file")
    
    if [ "$file_size" -lt "$min_size" ]; then
        log_error "Segment $segment_index trop petit (${file_size} octets < ${min_size} octets), tentative de reconversion..."
        
        # Tentatives de reconversion
        for ((retry=1; retry<=retry_count; retry++)); do
            log "Tentative $retry/$retry_count pour le segment $segment_index"
            
            # Supprimer l'ancien segment
            rm -f "$segment_file"
            
            # Reconvertir le segment avec un délai aléatoire
            sleep $((RANDOM % 3 + 1))
            local new_segment=$(transcode_segment "$input_file" "${segment_file%_*}.mp4" "$start_time" "$duration" "$segment_index" "$total_segments")
            
            if [ $? -eq 0 ]; then
                local new_size=$(stat -c %s "$new_segment")
                if [ "$new_size" -ge "$min_size" ]; then
                    log "✅ Reconversion réussie pour segment $segment_index (nouvelle taille: $new_size octets)"
                    return 0
                fi
            fi
        done
        
        log_error "❌ Échec après $retry_count tentatives pour segment $segment_index"
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
    
    # NOUVEAU: On assainit les noms de fichiers problématiques avant tout traitement
    sanitize_filename "$input_dir"
    
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