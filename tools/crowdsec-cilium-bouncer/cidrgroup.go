package main

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
)

// CiliumCIDRGroup mirrors cilium.io/v2 CiliumCIDRGroup. Only the field this
// bouncer writes is declared: importing github.com/cilium/cilium for one
// struct would pull in most of Cilium's dependency tree.
type CiliumCIDRGroup struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec CiliumCIDRGroupSpec `json:"spec"`
}

type CiliumCIDRGroupSpec struct {
	ExternalCIDRs []string `json:"externalCIDRs"`
}

type CiliumCIDRGroupList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`

	Items []CiliumCIDRGroup `json:"items"`
}

var groupVersion = schema.GroupVersion{Group: "cilium.io", Version: "v2"}

func newScheme() *runtime.Scheme {
	s := runtime.NewScheme()
	if err := clientgoscheme.AddToScheme(s); err != nil {
		panic(err)
	}
	s.AddKnownTypes(groupVersion, &CiliumCIDRGroup{}, &CiliumCIDRGroupList{})
	metav1.AddToGroupVersion(s, groupVersion)
	return s
}

func (in *CiliumCIDRGroup) DeepCopyObject() runtime.Object {
	out := *in
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec.ExternalCIDRs = append([]string(nil), in.Spec.ExternalCIDRs...)
	return &out
}

func (in *CiliumCIDRGroupList) DeepCopyObject() runtime.Object {
	out := *in
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	out.Items = make([]CiliumCIDRGroup, len(in.Items))
	for i := range in.Items {
		out.Items[i] = *in.Items[i].DeepCopyObject().(*CiliumCIDRGroup)
	}
	return &out
}
