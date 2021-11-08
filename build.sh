#!/bin/bash


NAME=xubuntu20043
USER=test
PASS=test
CPU=4
MEM=4096


# preqs
{
  vboxmanage -v
  aria2c -v
  sshpass -V
} &> /dev/null || { echo 'Install virtualbox, aria2c, sshpass!'; return 1; }


cd tmp


# download iso
URL="https://torrent.ubuntu.com/xubuntu/releases/focal/release/desktop/xubuntu-20.04.3-desktop-amd64.iso.torrent"
TORRENT=${URL##*/}

ISO="${TORRENT%.*}"
if [ ! -f "$ISO" ]; then
    wget $URL
    aria2c --seed-time=0 "$TORRENT"
fi


# create vm
vboxmanage createvm --name $NAME --ostype "Ubuntu_64" --register --basefolder $(pwd)

# set cpu, memory, network
vboxmanage modifyvm $NAME --cpus $CPU
vboxmanage modifyvm $NAME --ioapic on
vboxmanage modifyvm $NAME --memory $MEM --vram 128
vboxmanage modifyvm $NAME --nic1 nat
vboxmanage modifyvm $NAME --nic2 hostonly --hostonlyadapter2 vboxnet0

# create and attach disk
vboxmanage createhd --filename $(pwd)/$NAME/$NAME.vdi --size 50000 --format VDI
vboxmanage storagectl $NAME --name "SATA Controller" --add sata --controller IntelAhci
vboxmanage storageattach $NAME --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium $(pwd)/$NAME/$NAME.vdi

# attach iso
vboxmanage storagectl $NAME --name "IDE Controller" --add ide --controller PIIX4
ISO="${TORRENT%.*}"
vboxmanage storageattach $NAME --storagectl "IDE Controller" --port 1 --device 0 --type dvddrive --medium $(pwd)/$ISO
vboxmanage modifyvm $NAME --boot1 dvd --boot2 disk --boot3 none --boot4 none

# fix gui unattended install
# https://superuser.com/questions/1453425/vboxmanage-unattended-installation-of-debian-ubuntu-waits-for-input
aux_base_path="$(mktemp -d --tmpdir unattended-install-$NAME-XXXXX)"

cd ..

vboxmanage unattended install $NAME \
  --iso $(pwd)/tmp/$ISO \
  --user $USER \
  --password $PASS \
  --country US \
  --time-zone UTC \
  --hostname xubuntu.local \
  --install-additions \
  --script-template $(pwd)/ubuntu_preseed.cfg \
  --post-install-template $(pwd)/debian_postinstall.sh \
  --auxiliary-base-path "$aux_base_path"/
sed -i 's/^default vesa.*/default install/' "$aux_base_path"/isolinux-isolinux.cfg

# shared folder
vboxmanage sharedfolder add $NAME --name shared -hostpath $(pwd) -automount

# start vm
vboxmanage startvm $NAME


# wait for ssh
GET_IP () {
    vboxmanage guestproperty get $NAME "/VirtualBox/GuestInfo/Net/1/V4/IP" | awk '{print $2}'
}

SECONDS=0
{
  while ! echo -n > /dev/tcp/$(GET_IP)/22; do
    echo -ne "waiting for vm, elapsed: ${SECONDS}s\033[0K\r"
    sleep 1
  done
} 2>/dev/null
echo ""


# provision
sshpass -p test scp -o StrictHostKeyChecking=no playbook.yml test@$(GET_IP):~
sshpass -p test ssh -o StrictHostKeyChecking=no test@$(GET_IP) <<EOF
  cd ~
  wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
  export INSTALL_DIR=~/miniconda3
  bash Miniconda3-latest-Linux-x86_64.sh -b -f -p $INSTALL_DIR
  PATH=\$INSTALL_DIR/bin:\$PATH
  conda update -y conda
  conda install -c conda-forge -y ansible
  ansible-playbook playbook.yml --user=$USER --extra-vars "ansible_sudo_pass=$PASS"
EOF

vboxmanage controlvm $NAME reset

echo "done!"

