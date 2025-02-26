#!/bin/bash

# On définit le dossier de sortie
OUTPUT_DIR="/output"
mkdir -p "$OUTPUT_DIR"

# On définit une fonction pour convertir les fichiers
convert_file() {
    local input_file="$1"
    local output_file="$2"
    
    echo "Conversion du fichier: $(basename "$input_file")"
    
    # Détection du format vidéo
    local video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file")
    echo "Codec détecté: $video_codec"
    
    # Obtention de la durée de la vidéo pour calculer la progression
    local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_file")
    duration=${duration%.*} # On supprime la partie décimale
    
    # Fonction pour afficher la barre de progression
    progress_bar() {
        local current_time=$1
        local percent=$((current_time * 100 / duration))
        
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
        
        # Affichage sur la même ligne en écrasant le contenu précédent
        echo -ne "\r$progress_bar Temps: $current_time/$duration s"
    }
    
    # Options de base communes aux deux méthodes
    local common_opts=(-map 0:v:0 -map 0:a:0 
                      -c:v h264_nvenc -preset p4 -profile:v main -level 4.1 -b:v 2M -maxrate 2.5M -bufsize 5M 
                      -c:a aac -b:a 192k -ac 2 
                      -movflags +faststart 
                      -metadata:s:v language=und -metadata:s:a language=und 
                      -map_chapters -1 
                      -f mp4)
    
    # Conversion avec différentes options selon le codec source
    if [[ "$video_codec" == "vp9" || "$video_codec" == "vp8" ]]; then
        echo "⚠️ Codec VP8/VP9 détecté - utilisation du décodage logiciel"
        # On lance ffmpeg avec la fonction de progression
        ffmpeg -i "$input_file" "${common_opts[@]}" -progress pipe:1 "$output_file" 2>&1 | \
        while read line; do
            # Extraction du temps écoulé
            if [[ "$line" == out_time_ms* ]]; then
                # Convertir les microsecondes en secondes
                current_time=$((${line#out_time_ms=} / 1000000))
                progress_bar $current_time
            fi
        done
        echo # Nouvelle ligne après la barre de progression
    else
        # Accélération matérielle pour les autres codecs
        echo "🚀 Utilisation de l'accélération GPU CUDA"
        ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i "$input_file" "${common_opts[@]}" -progress pipe:1 "$output_file" 2>&1 | \
        while read line; do
            # Extraction du temps écoulé
            if [[ "$line" == out_time_ms* ]]; then
                # Convertir les microsecondes en secondes
                current_time=$((${line#out_time_ms=} / 1000000))
                progress_bar $current_time
            fi
        done
        echo # Nouvelle ligne après la barre de progression
    fi
    
    # Vérification que le fichier a bien été créé
    if [ -f "$output_file" ]; then
        echo "✅ Conversion réussie: $(basename "$output_file")"
    else
        echo "❌ Échec de conversion pour: $(basename "$input_file")"
    fi
}

# Fonction pour traiter un dossier
process_directory() {
    local input_dir="$1"
    
    echo "🔍 Recherche de fichiers vidéo dans: $input_dir"
    
    # Compteurs pour le suivi
    local total_files=0
    local converted_files=0
    local failed_files=0
    
    # On parcourt tous les formats vidéo courants
    for ext in mp4 mkv avi mov webm wmv flv ts m4v; do
        for file in "$input_dir"/*.$ext "$input_dir"/*.$ext; do
            # Vérifie si le fichier existe (évite les problèmes avec les wildcards)
            if [ -f "$file" ]; then
                total_files=$((total_files + 1))
                
                # On récupère le nom du fichier sans l'extension
                filename=$(basename -- "$file")
                basename="${filename%.*}"
                
                # On crée le chemin de sortie
                output_file="$OUTPUT_DIR/${basename}.mp4"
                
                # On vérifie si le fichier existe déjà
                #if [ -f "$output_file" ]; then
                #    echo "⏩ Fichier déjà converti: $output_file"
                #else
                # On lance la conversion
                if convert_file "$file" "$output_file"; then
                    converted_files=$((converted_files + 1))
                else
                    failed_files=$((failed_files + 1))
                fi
                #fi
            fi
        done
    done
    
    echo "📊 Résumé:"
    echo "  - Total de fichiers trouvés: $total_files"
    echo "  - Fichiers convertis avec succès: $converted_files"
    echo "  - Échecs de conversion: $failed_files"
}

# Point d'entrée principal
main() {
    local input_dir="/input"
    
    # Vérification que le dossier d'entrée existe
    if [ ! -d "$input_dir" ]; then
        echo "❌ Erreur: Le dossier d'entrée $input_dir n'existe pas!"
        exit 1
    fi
    
    # Vérification que le dossier de sortie existe
    if [ ! -d "$OUTPUT_DIR" ]; then
        echo "📁 Création du dossier de sortie: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
    fi
    
    echo "🚀 Démarrage du processus de conversion pour IPTV"
    process_directory "$input_dir"
    echo "✨ Toutes les conversions sont terminées!"
}

# Exécution du script
main "$@"