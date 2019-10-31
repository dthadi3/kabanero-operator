#!/bin/bash

set -Eeox pipefail

RELEASE="${RELEASE:-0.3.0}"
KABANERO_SUBSCRIPTIONS_YAML="${KABANERO_SUBSCRIPTIONS_YAML:-https://github.com/kabanero-io/kabanero-operator/releases/download/$RELEASE/kabanero-subscriptions.yaml}"
KABANERO_CUSTOMRESOURCES_YAML="${KABANERO_CUSTOMRESOURCES_YAML:-https://github.com/kabanero-io/kabanero-operator/releases/download/$RELEASE/kabanero-customresources.yaml}"
SLEEP_LONG="${SLEEP_LONG:-5}"
SLEEP_SHORT="${SLEEP_SHORT:-2}"

# Check Subscriptions: subscription-name, namespace
checksub () {
	echo "Waiting for Subscription $1 InstallPlan to complete."

	# Wait for the InstallPlan to be generated and available on status
	unset INSTALL_PLAN
	until oc get subscription $1 -n $2 --output=jsonpath={.status.installPlanRef.name}
	do
		sleep $SLEEP_SHORT
	done

	# Get the InstallPlan
	until [ -n "$INSTALL_PLAN" ]
	do
		sleep $SLEEP_SHORT
		INSTALL_PLAN=$(oc get subscription $1 -n $2 --output=jsonpath={.status.installPlanRef.name})
	done

	# Wait for the InstallPlan to Complete
	unset PHASE
	until [ "$PHASE" == "Complete" ]
	do
		PHASE=$(oc get installplan $INSTALL_PLAN -n $2 --output=jsonpath={.status.phase})
		sleep $SLEEP_SHORT
	done
	
	# Get installed CluserServiceVersion
	unset CSV
	until [ -n "$CSV" ]
	do
		sleep $SLEEP_SHORT
		CSV=$(oc get subscription $1 -n $2 --output=jsonpath={.status.installedCSV})
	done
	
	# Wait for the CSV
	unset PHASE
	until [ "$PHASE" == "Succeeded" ]
	do
		PHASE=$(oc get clusterserviceversion $CSV -n $2 --output=jsonpath={.status.phase})
		sleep $SLEEP_SHORT
	done
}

### CatalogSource

# Install Kabanero CatalogSource
oc apply -f $KABANERO_SUBSCRIPTIONS_YAML --selector kabanero.io/install=00-catalogsource

# Check the CatalogSource is ready
unset LASTOBSERVEDSTATE
until [ "$LASTOBSERVEDSTATE" == "READY" ]
do
	echo "Waiting for CatalogSource kabanero-catalog to be ready."
	LASTOBSERVEDSTATE=$(oc get catalogsource kabanero-catalog -n openshift-marketplace --output=jsonpath={.status.connectionState.lastObservedState})
	sleep $SLEEP_SHORT
done

### Subscriptions

# Install 10-subscription (elasticsearch, jaeger, kiali)
oc apply -f $KABANERO_SUBSCRIPTIONS_YAML --selector kabanero.io/install=10-subscription

# Verify Subscriptions
checksub elasticsearch-operator openshift-operators
checksub jaeger-product openshift-operators
checksub kiali-ossm openshift-operators

# Install 11-subscription (servicemesh)
oc apply -f $KABANERO_SUBSCRIPTIONS_YAML --selector kabanero.io/install=11-subscription

# Verify Subscriptions
checksub servicemeshoperator openshift-operators

# Install 12-subscription (eventing, serving)
oc apply -f $KABANERO_SUBSCRIPTIONS_YAML --selector kabanero.io/install=12-subscription

# Verify Subscriptions
checksub knative-eventing-operator-alpha-community-operators-openshift-marketplace openshift-operators
checksub serverless-operator openshift-operators

# Install 13-subscription (pipelines, appsody)
oc apply -f $KABANERO_SUBSCRIPTIONS_YAML --selector kabanero.io/install=13-subscription

# Verify Subscriptions
checksub openshift-pipelines-operator-dev-preview-community-operators-openshift-marketplace openshift-operators
checksub appsody-operator-certified-beta-certified-operators-openshift-marketplace openshift-operators

# Install 14-subscription (che, kabanero)
oc apply -f $KABANERO_SUBSCRIPTIONS_YAML --selector kabanero.io/install=14-subscription

# Verify Subscriptions
checksub eclipse-che kabanero
checksub kabanero-operator kabanero


### CustomResources

# ServiceMeshControlplane
oc apply -f $KABANERO_CUSTOMRESOURCES_YAML --selector kabanero.io/install=20-cr-servicemeshcontrolplane

# Check the ServiceMeshControlPlane is ready, last condition should reflect readiness
unset STATUS
unset TYPE
until [ "$STATUS" == "True" ] && [ "$TYPE" == "Ready" ]
do
	echo "Waiting for ServiceMeshControlPlane basic-install to be ready."
	TYPE=$(oc get servicemeshcontrolplane -n istio-system basic-install --output=jsonpath={.status.conditions[-1:].type})
	STATUS=$(oc get servicemeshcontrolplane -n istio-system basic-install --output=jsonpath={.status.conditions[-1:].status})
	sleep $SLEEP_SHORT
done

# ServiceMeshMemberRole
oc apply -f $KABANERO_CUSTOMRESOURCES_YAML --selector kabanero.io/install=21-cr-servicemeshmemberrole

# Serving
oc apply -f $KABANERO_CUSTOMRESOURCES_YAML --selector kabanero.io/install=22-cr-knative-serving

# Check the KnativeServing is ready, last condition should reflect readiness
unset STATUS
unset TYPE
until [ "$STATUS" == "True" ] && [ "$TYPE" == "Ready" ]
do
	echo "Waiting for KnativeServing knative-serving to be ready."
	TYPE=$(oc get knativeserving knative-serving -n knative-serving --output=jsonpath={.status.conditions[-1:].type})
	STATUS=$(oc get knativeserving knative-serving -n knative-serving --output=jsonpath={.status.conditions[-1:].status})
	sleep $SLEEP_SHORT
done

# Kabanero
oc apply -f $KABANERO_CUSTOMRESOURCES_YAML --selector kabanero.io/install=23-cr-kabanero

# Check the Kabanero is ready
unset READY
until [ "$READY" == "True" ]
do
	echo "Waiting for Kabanero kabanero to be ready."
	READY=$(oc get kabanero kabanero -n kabanero --output=jsonpath={.status.kabaneroInstance.ready})
	sleep $SLEEP_SHORT
done


# Github Sources
oc apply -f https://github.com/knative/eventing-contrib/releases/download/v0.9.0/github.yaml

# Need to wait for knative serving CRDs before installing tekton webhook extension
until oc get crd services.serving.knative.dev 
do
	echo "Waiting for CustomResourceDefinition services.serving.knative.dev to be ready."
	sleep $SLEEP_SHORT
done

# Tekton Dashboard
oc new-project tekton-pipelines || true
oc apply -f https://github.com/tektoncd/dashboard/releases/download/v0.2.0/openshift-webhooks-extension.yaml
oc apply -f https://github.com/tektoncd/dashboard/releases/download/v0.2.0/openshift-tekton-dashboard.yaml
