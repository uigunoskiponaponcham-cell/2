#!/bin/bash
#Версия v4.0

# Настройки майнера
WAL=42BocciF6ZwzT2itWqjSiGftRT9KUuGNb5
WKN=Izao_Ferma_5_1920x
PW="d=0.2"  #Рекомендуемые значения 0.2 на 10C/s, дает стабильный хеш на пуле, для 1C/s 0.02

# Интенсивность
COUNT=5     # Кол-во экземпляров
THR=4        # Кол-во потоков на экземпляр
INT=-20      # Лучшее - -20, худшее - 20, увеличивать при слете экземпляров
MSRMOD=true  # Индивидуально true/false. Поддерживает Intel Nehalem+ и AMD zen(1-4)


# Команда без taskset (он добавится позже)
BASE_CMD="nice -n $INT ./jtminer-1.0-Stratum-jar-with-dependencies -u ${WAL}.${WKN} -h tht.mine-n-krush.org -p $PW -P 5001 -t $THR"

#Отладчик
log_path="/mnt/ramlogdisk" # Если отказываться от ramdiskа, то изменить на /var/log
log_pattern="miner-*.log"  # Название логов майнера, пока CONST
log_lines_keep=18000       # максимальное количество строк в логе. Чтобы не засорять память.
interval=30                # интервал вывода показателей (сек). Можно снизить, чуть улучшит производиьельность. Стандарт 30, можно и 15 и любое др. значение
ramdisk=true               # Включить логирование на ОЗУ чтобы не тратить ресурс диска true/false
startlat=1.0               # Задержка перед запуском следущей screen сессии. Не факт но может влиять. Пока неподтверждено поэтому 0.0, ради тестов можно 1.0

# Окончание настроек
###############################################################################

killall java
#Ramlogdisk
if [ "$ramdisk" = true ]; then
    mkdir -p /mnt/ramlogdisk
    mount -t tmpfs -o size=1G tmpfs /mnt/ramlogdisk
else
    umount /mnt/ramlogdisk 2>/dev/null
    rm -rf /mnt/ramlogdisk
fi

# MSRMOD

if [ "$MSRMOD" = true ]; then
        echo "MSRMOD is enabled"
        modprobe msr allow_writes=on
        if grep -E 'AMD Eng Sample|AMD Ryzen|AMD EPYC' /proc/cpuinfo > /dev/null;
          then
          if grep "cpu family[[:space:]]\{1,\}:[[:space:]]25" /proc/cpuinfo > /dev/null;
            then
              if grep "model[[:space:]]\{1,\}:[[:space:]]97" /proc/cpuinfo > /dev/null;
                then
                  echo "Detected Zen4 CPU"
                  wrmsr -a 0xc0011020 0x4400000000000
                  wrmsr -a 0xc0011021 0x4000000000040
                  wrmsr -a 0xc0011022 0x8680000401570000
                  wrmsr -a 0xc001102b 0x2040cc10
                  echo "MSR register values for Zen4 applied"
                else
                  echo "Detected Zen3 CPU"
                  wrmsr -a 0xc0011020 0x4480000000000
                  wrmsr -a 0xc0011021 0x1c000200000040
                  wrmsr -a 0xc0011022 0xc000000401570000
                  wrmsr -a 0xc001102b 0x2000cc10
                  echo "MSR register values for Zen3 applied"
                fi
            else
              echo "Detected Zen1/Zen2 CPU"
              wrmsr -a 0xc0011020 0
              wrmsr -a 0xc0011021 0x40
              wrmsr -a 0xc0011022 0x1510000
              wrmsr -a 0xc001102b 0x2000cc16
              echo "MSR register values for Zen1/Zen2 applied"
            fi
        elif grep "Intel" /proc/cpuinfo > /dev/null;
          then
            echo "Detected Intel CPU"
            wrmsr -a 0x1a4 0xf
            echo "MSR register values for Intel applied"
        else
          echo "No supported CPU detected"
          echo "Failed to apply MSRMOD"
        fi
else
  echo "MSRMOD is disabled"
fi

# RAMFREQ
ramfr=$(sudo dmidecode --type memory | grep "Configured Memory Speed" | awk -F': ' '{print $2}' | head -n1)
rams=$(sudo dmidecode --type memory | grep -i "Size:" | grep -v "No Module Installed" | awk '{sum += $2} END {print sum " GB"}')

# Запуск экземпляров с привязкой к ядрам
for i in $(seq 0 $((COUNT - 1))); do
    SESSION="miner-$((i+1))"
    CPU_START=$((i * THR))
    CPU_END=$((CPU_START + THR - 1))
    # Формируем список ядер: например, "0,1,2,3"
    CPU_LIST=$(seq -s, $CPU_START $CPU_END)
    echo "[+] Запускаю screen-сессию $SESSION на ядрах $CPU_LIST"
    screen -L -Logfile /mnt/ramlogdisk/"miner-$((i+1))".log -dmS "$SESSION" bash -c "$BASE_CMD"
    sleep "$startlat"
done

echo "[✓] Все $COUNT screen-сессий запущены с CPU-биндингом."

# Размеры скользящих окон
size_1m=$((60 / interval))
size_5m=$((300 / interval))
size_15m=$((900 / interval))
size_60m=$((3600 / interval))
# Массивы для хранения значений
declare -a window_1m=()
declare -a window_5m=()
declare -a window_15m=()
declare -a window_60m=()
# ======================= ФУНКЦИИ ===========================
calc_avg() {
  local arr=("$@")
  local acc=0
  for v in "${arr[@]}"; do
    acc=$(echo "$acc + $v" | bc)
  done
  echo "scale=2; $acc / ${#arr[@]}" | bc
}
cpu_model=$(lscpu | grep 'Model name' | head -1 | sed 's/Model name:[ \t]*//')
count_cores() {
  grep -E 'physical id|core id' /proc/cpuinfo | paste - - | sort -u | wc -l
}
get_temps() {
  if ! command -v sensors &>/dev/null; then
    echo "Temp: Unavailable (sensors не установлен)"
    return
  fi

  # Ищем строки с общей температурой CPU
  temp_line=$(sensors | grep -E 'Package id [0-9]+:|Tctl:|Tdie:|CPU Temp:' | head -n 5)

  if [ -z "$temp_line" ]; then
    echo "Temp: Не удалось найти общую температуру CPU"
    return
  fi

  # Извлекаем и форматируем температуры
  temps=$(echo "$temp_line" | awk -F':' '{print $2}' | sed 's/^[[:space:]]*+//' | sed 's/°C.*//' | \
    awk '{temps[i++]=$1} END {
      for(j=0; j<i; j++) {
        printf "%s °C", temps[j];
        if(j<i-1) printf " | ";
      }
      printf "\n";
    }')

  echo "$temps"
}

# ======================= ОСНОВНОЙ ЦИКЛ =====================
while true; do
  clear
  echo "========================== Jtscript v4.0 for Jtminer ==========================="
  echo "================================================================================"
  sum=0
  count=0
  for file in "$log_path"/$log_pattern; do
    if [[ -f $file ]]; then
      total_lines=$(wc -l < "$file")
      if (( total_lines > log_lines_keep * 2 )); then
        tail -n "$log_lines_keep" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      fi
      line=$(grep "Miner Stats:" "$file" | tail -n 1)
      sol_raw=$(echo "$line" | grep -oP '[0-9]+\.[0-9]+(?= Sol/s)')
      if [ -z "$sol_raw" ]; then
        sol_raw=$(echo "$line" | grep -oP '[0-9]+,[0-9]+(?= Sol/s)' | tr ',' '.')
      fi

      if [[ -n $sol_raw ]]; then
        sol_dot=${sol_raw/,/.}
        sum=$(echo "$sum + $sol_dot" | bc)
        count=$((count + 1))
      fi
    fi
  done
  if (( count > 0 )); then
    total=$(echo "$sum" | bc)
    window_1m+=("$total")
    window_5m+=("$total")
    window_15m+=("$total")
    window_60m+=("$total")
    (( ${#window_1m[@]} > size_1m )) && window_1m=("${window_1m[@]:1}")
    (( ${#window_5m[@]} > size_5m )) && window_5m=("${window_5m[@]:1}")
    (( ${#window_15m[@]} > size_15m )) && window_15m=("${window_15m[@]:1}")
    (( ${#window_60m[@]} > size_60m )) && window_60m=("${window_60m[@]:1}")
    avg_1m=$(calc_avg "${window_1m[@]}")
    avg_5m=$(calc_avg "${window_5m[@]}")
    avg_15m=$(calc_avg "${window_15m[@]}")
    avg_60m=$(calc_avg "${window_60m[@]}")
    threads=$(grep -c ^processor /proc/cpuinfo)
    cores=$(count_cores)
    freq=$(awk -F: '/cpu MHz/ {print int($2); exit}' /proc/cpuinfo)
    temps=$(get_temps)
    printf "\n\033[1;32m[%s] HASHRATE ============================================================\033[0m\n" "$(date '+%H:%M:%S')"
    printf "  Now:   %s C/s\n" "$total"
    printf "  1 min: %s C/s\n" "$avg_1m"
    printf "  5 min: %s C/s\n" "$avg_5m"
    printf " 15 min: %s C/s\n" "$avg_15m"
    printf " 60 min: %s C/s\n" "$avg_60m"
    printf "\033[1;32m================================================================================\033[0m\n"
    echo "CPU: $cpu_model"
    echo "Cores: $cores | Threads: $threads | Freq: ${freq:-Unknown} MHz | RAM: ${rams}/${ramfr} | TH/EX: ${THR}/${COUNT}"
    if [[ "$temps" != "Unavailable" && -n "$temps" ]]; then
      echo "Temp(s): $temps"
    else
      echo "Temp: Unavailable"
    fi
    echo "--------------------------------------------------------------------------------"
  else
    echo "[$(date '+%H:%M:%S')] No valid data found in logs."
  fi
  sleep "$interval"
done

