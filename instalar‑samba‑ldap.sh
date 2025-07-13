#!/usr/bin/env bash
#
# Script ...: instalar‑samba‑ldap.sh
# Descricao : Faz a instalação do SAMBA+LDAP
# Autor ....: Eugenio Oliveira
#
# Pré-requisito obrigatório
# pkg install -y bash
#
# trap 'MostraMSG ERRO "Falha na linha $LINENO"; exit 1' ERR
# set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "Execute como root"; exit 1; fi

function MostraMSG() {

   INFO=$(echo $1|tr '[:lower:]' '[:upper:]')
   echo $(date +"%d-%m-%Y %H:%M:%S")" - [$INFO] - $2"

}

function GerenciarServicos() {

   TIPO=$1
   MSG="Iniciando"

   if [ $TIPO = "stop" ]; then MSG="Parando" ; fi

   if [ $TIPO = "start" ]; then
      MostraMSG INFO "Ativando serviços no rc.conf"
      sysrc samba_server_enable="YES" > /dev/null 2>&1
      sysrc nmbd_enable=NO > /dev/null 2>&1
      sysrc slapd_enable="YES" > /dev/null 2>&1
      sysrc nslcd_enable="YES" > /dev/null 2>&1
   fi

   MostraMSG INFO $MSG" os serviços"
   for SVC in slapd nslcd samba_server ; do
       RESP=$(service -e | grep -w "$SVC")
       if [ -n "$RESP" ]; then
          service $SVC $TIPO > /dev/null 2>&1
          RESP=$?
          if [ $TIPO = "start" ]; then
             if [ $RESP -ne 0 ]; then
                MostraMSG INFO "  falhou [$SVC]"
             else
                MostraMSG INFO "  ok [$SVC]"
             fi
          else
             MostraMSG INFO "  ok [$SVC]"
          fi
       fi
   done

}

echo ""
MostraMSG INFO "Iniciando o processo de instalação do SAMPA com LDAP"

MostraMSG INFO "Definindo as variáveis"
sambaDomain="BRASIL"
LDAPo="SUA Empresa"
LDAPurl="ldap://ldap.brasil.local"
LDAPsuffix="dc=brasil,dc=local"
LDAPdc="brasil"
LDAPadmin="cn=Manager,${LDAPsuffix}"
LDAPpass="FX$(date | md5sum | head -c10 ; echo)"
LDAPmailDomain="brasilengenharia.com.br"

LDAPdns=$(echo ${LDAPurl#'ldap://'})
MostraMSG INFO "Validando DNS para ${LDAPdns}"
ping -q -c 1 ${LDAPdns} > /dev/null 2>&1
if [ $? -ne 0 ]; then
   MostraMSG ERRO "Não foi possível resolver o nome ${LDAPdns}"
   exit 1
fi

MostraMSG INFO "Atualizando e migrando o ports"
IGNORE_OSVERSION=yes pkg update -q > /dev/null 2>&1 && pkg upgrade -y > /dev/null 2>&1
if [ $? -ne 0 ]; then
   MostraMSG ERRO "Não foi possível atualizar o FreeBSD"
   exit 1
fi

MostraMSG INFO "Instalando os pacotes e dependências necessárias"
pkg install -y samba420 openldap26-server openldap26-client sudo smbldap-tools nss-pam-ldapd > /dev/null 2>&1
if [ $? -ne 0 ]; then
   MostraMSG ERRO "Não foi possível instalar os pacotes do samba openldap e nss"
   exit 1
fi

MostraMSG INFO "Pegando o SID Local"
echo -e "
[global]
   workgroup = ${sambaDomain}
   server string = Servidor de Arquivos Samba + LDAP
   netbios name = $(hostname -s)
   security = user
" > /usr/local/etc/smb4.conf
sambaSID="$(net getlocalsid|awk '{print $NF}')"

MostraMSG INFO "Definindo o SID do domínio"
net setdomainsid ${sambaSID} > /dev/null 2>&1
if [ $? -ne 0 ]; then
   MostraMSG ERRO "Não foi possível obter o SID para continuar"
   exit 1
fi

GerenciarServicos stop

MostraMSG INFO "Download do samba.shema"
fetch -q https://raw.githubusercontent.com/mwaeckerlin/openldap/refs/heads/master/samba.schema -o /usr/local/etc/openldap/schema/samba.schema
if [ $? -ne 0 ]; then
   MostraMSG ERRO "Não foi possível baixr o samba.schea do GitHUB"
   exit 1
fi

MostraMSG INFO "Download do qmail.schema"
fetch -q https://raw.githubusercontent.com/qmail-ldap/qmail-ldap/refs/heads/master/qmail.schema -o /usr/local/etc/openldap/schema/qmail.schema
if [ $? -ne 0 ]; then
   MostraMSG ERRO "Não foi possível baixr o qmail.schema do GitHUB"
   exit 1
fi

MostraMSG INFO "Criando os diretórios necessários"
mkdir -p /rede/publico

MostraMSG INFO "Gerando os arquivos de configurações"
echo -e "
dn: ${LDAPsuffix}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAPo}
dc: ${LDAPdc}

dn: ${LDAPadmin}
objectClass: organizationalRole
cn: Manager
description: Administrador do Directorio

dn: ou=Policies,${LDAPsuffix}
objectClass: organizationalUnit
ou: Policies

dn: cn=default,ou=Policies,${LDAPsuffix}
objectClass: pwdPolicy
objectClass: person
cn: default
sn: policy
pwdAttribute: userPassword
pwdInHistory: 5
pwdMinLength: 10
" > /tmp/base.ldif
MostraMSG INFO "  ok [base.ldif]"

echo -e "
[global]
   workgroup = ${sambaDomain}
   server string = Servidor de Arquivos Samba + LDAP
   netbios name = $(hostname -s)
   security = user
   passdb backend = ldapsam:${LDAPurl}
   ldap admin dn = ${LDAPadmin}
   ldap suffix = ${LDAPsuffix}
   ldap user suffix = ou=Users
   ldap group suffix = ou=Groups
   ldap machine suffix = ou=Computers
   ldap ssl = no
   log file = /var/log/samba4/log.%m
   max log size = 50
   log level = 1
   load printers = no
   disable spoolss = yes

   use sendfile = no
   vfs objects = full_audit
   full_audit:facility = local5
   full_audit:priority = notice
   full_audit:prefix = %u|%I|%S
   full_audit:success = renameat unlinkat mkdirat
   full_audit:failure = none

   timeserver = Yes
   veto files = /*.bat/*.com/*.lnk/*.asd/*.shb/*.vb/*.wsf/*.wsh/*.pif/*.scr/*.chm/*.hta/*.shs/*.vbs/*.vbe/*.js/*.jse/*.3gp/*.aaa/*.bbb/*.Bbbb/*.ccc/*.eee/*.fff/
   deadtime = 10
   #guest account = nobody
   #map to guest = Bad User
   dont descend = /proc,/dev,/etc,/lib,/lost+found,/initrd
   preserve case = yes
   short preserve case = yes
   case sensitive = no

   map hidden = No
   map system = No
   map archive = No
   map read only = No
   store dos attributes = Yes

   create mask = 0666
   directory mask = 0777

   ldap passwd sync              = Yes
   idmap config * : backend = tdb
   idmap config * : range   = 3000-7999
   idmap config ${sambaDomain} : backend  = ldap
   idmap config ${sambaDomain} : range    = 10000-99999
   idmap config ${sambaDomain} : ldap_url = ${LDAPurl}
   idmap config ${sambaDomain} : ldap_base_dn = ${LDAPsuffix}

   map acl inherit = Yes
   unix charset = ISO8859-1
   Dos charset = CP850
   template shell = /bin/false

[publico]
   path = /rede/publico
   read only = No
   browseable = No

" > /usr/local/etc/smb4.conf
MostraMSG INFO "  ok [smb4.conf]"

echo -e "
uid nslcd
gid nslcd
uri ${LDAPurl}
base ${LDAPsuffix}
binddn ${LDAPadmin}
bindpw ${LDAPpass}
ssl no
" > /usr/local/etc/nslcd.conf
MostraMSG INFO "  ok [nslcd.conf]"

cat <<EOF> /usr/local/etc/smbldap-tools/smbldap.conf
sambaDomain="${sambaDomain}"
sambaSID="${sambaSID}"
slaveLDAP="${LDAPurl}"
masterLDAP="${LDAPurl}"
ldapTLS="0"
verify="require"
cafile="/etc/smbldap-tools/ca.pem"
clientcert="/etc/smbldap-tools/smbldap-tools.pem"
clientkey="/etc/smbldap-tools/smbldap-tools.key"
suffix="${LDAPsuffix}"
usersdn="ou=Users,${LDAPsuffix}"
computersdn="ou=Computers,${LDAPsuffix}"
groupsdn="ou=Groups,${LDAPsuffix}"
idmapdn="ou=Idmap,${LDAPsuffix}"
sambaUnixIdPooldn="sambaDomainName=${sambaDomain},${LDAPsuffix}"
scope="sub"
password_hash="SSHA"
password_crypt_salt_format="%s"
userLoginShell="/bin/bash"
userHome="/home/%U"
userHomeDirectoryMode="700"
userGecos="System User"
defaultUserGid="513"
defaultComputerGid="515"
shadowAccount="1"
mailDomain="${LDAPmailDomain}"
lanmanPassword="0"
with_smbpasswd="0"
smbpasswd="/usr/bin/smbpasswd"
with_slappasswd="0"
slappasswd="/usr/sbin/slappasswd"
EOF
MostraMSG INFO "  ok [smbldap.conf]"

cat <<EOF> /usr/local/etc/smbldap-tools/smbldap_bind.conf
masterDN="${LDAPadmin}"
masterPw="${LDAPpass}"
EOF
MostraMSG INFO "  ok [smbldap_bind.conf]"

echo -e "
BASE    ${LDAPsuffix}
URI     ${LDAPurl}
" > /usr/local/etc/openldap/ldap.conf
MostraMSG INFO "  ok [ldap.conf]"

echo -e "
include         /usr/local/etc/openldap/schema/core.schema
include         /usr/local/etc/openldap/schema/corba.schema
include         /usr/local/etc/openldap/schema/cosine.schema
include         /usr/local/etc/openldap/schema/dyngroup.schema
include         /usr/local/etc/openldap/schema/inetorgperson.schema
include         /usr/local/etc/openldap/schema/nis.schema
include         /usr/local/etc/openldap/schema/samba.schema
include         /usr/local/etc/openldap/schema/qmail.schema
pidfile         /var/run/openldap/slapd.pid
argsfile        /var/run/openldap/slapd.args
modulepath      /usr/local/libexec/openldap
moduleload      back_mdb
moduleload      ppolicy.la
database config
database        mdb
maxsize         1073741824
suffix          "${LDAPsuffix}"
rootdn          "${LDAPadmin}"
rootpw          $(slappasswd -n -s ${LDAPpass})
directory       /var/db/openldap-data
index           objectClass eq
index           uid,uidNumber,gidNumber eq
index           sambaSID,sambaPrimaryGroupSID eq
index           memberUid,member    eq

database monitor

overlay     ppolicy
ppolicy_default "cn=default,ou=Policies,${LDAPsuffix}"
ppolicy_use_lockout TRUE
" > /usr/local/etc/openldap/slapd.conf
MostraMSG INFO "  ok [slapd.conf]"

sed -i '' -e 's/^group:.*/group: files ldap/' \
          -e 's/^passwd:.*/passwd: files ldap/' /etc/nsswitch.conf

MostraMSG INFO "  ok [nsswitch.conf]"

cat <<EOF> /etc/syslog.d/samba.conf
local5.notice    /var/log/samba4/auditoria.log
EOF
touch /var/log/samba4/auditoria.log
MostraMSG INFO "  ok [syslog]"

MostraMSG INFO "Ajustando permissões de arquivos"
chmod 600 /usr/local/etc/smbldap-tools/*.conf /usr/local/etc/nslcd.conf

MostraMSG INFO "Importando o domínio raiz do LDAP"
slapadd -v -l /tmp/base.ldif > /dev/null 2>&1

MostraMSG INFO "Registrando a senha do SMB no secrets"
smbpasswd -w ${LDAPpass} > /dev/null 2>&1

/etc/rc.d/syslog restart > /dev/null 2>&1

GerenciarServicos start

MostraMSG INFO "Criando as entradas necessárias no LDAP"
sleep 15s
ln -sf /usr/local/etc/smb4.conf /usr/local/etc/smb.conf
echo -e "${LDAPpass}\n${LDAPpass}"|smbldap-populate > /dev/null 2>&1
if [ $? -ne 0 ]; then
   MostraMSG ERRO "Não foi possível popular LDAP corretamente"
   exit 1
fi

MostraMSG INFO "Fim da instalação"

echo -e "

A senha da conta Manager é: ${LDAPpass}
----------------------------------------------------------------------

Efetue os testes para saber se a instalação foi concluída com sucesso

# Verificar se os serviços subiram
sockstat -4 -l | grep -E 'slapd|smbd|nmbd|syslog'

# Testar o LDAP esta populado
ldapsearch -x -LLL -H ${LDAPurl} -b ${LDAPsuffix}

# Testar criação de usuários no LDAP pelo smbtools
smbldap-useradd -a -m eugenio.oliveira
smbldap-passwd eugenio.oliveira

# Teste o acesso ao SAMBA
No Linux:
smbclient -L //localhost/publico -U eugenio.oliveira

No Windows (Windows + X)"
echo '\\'$(hostname)

echo
