#!/bin/bash

echo "Starting cleanup process..."

# حلقه روی تمام کانتینرها
docker ps -a --format "{{.Names}}" | while read name; do
    
    # بررسی اینکه آیا نام با Conduit شروع می‌شود یا خیر
    if [[ "$name" == Conduit* ]]; then
        echo "✅ KEEPING container: $name"
    else
        echo "❌ DELETING container: $name"
        # دستور rm -f هم کانتینر را متوقف می‌کند (Stop) و هم حذف (Remove)
        docker rm -f $name
    fi

done

echo "Starting cleanup process..."

# حلقه روی تمام کانتینرها
docker ps -a --format "{{.Names}}" | while read name; do
    
    # بررسی اینکه آیا نام با Conduit شروع می‌شود یا خیر
    if [[ "$name" == conduit* ]]; then
        echo "✅ KEEPING container: $name"
    else
        echo "❌ DELETING container: $name"
        # دستور rm -f هم کانتینر را متوقف می‌کند (Stop) و هم حذف (Remove)
        docker rm -f $name
    fi

done


echo "Cleanup finished."